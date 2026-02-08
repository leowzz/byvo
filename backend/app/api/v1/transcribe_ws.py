"""WebSocket 流式转写：豆包 ASR，可选 Ark 纠错。"""

import asyncio
from collections.abc import AsyncIterator

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from loguru import logger

from app.config import settings
from app.services import ark_correction, volcengine

router = APIRouter()
CORRECTION_WINDOW_SEC = 1.8
CHECK_INTERVAL_CAP_SEC = 5.0
CORR_WAIT_TIMEOUT_SEC = 60.0
IDLE_TIMEOUT_MIN = 1
IDLE_TIMEOUT_MAX = 600


async def _audio_stream_from_ws(ws: WebSocket) -> AsyncIterator[bytes]:
    """从 WebSocket 读取二进制 PCM。"""
    try:
        while True:
            yield await ws.receive_bytes()
    except (WebSocketDisconnect, RuntimeError):
        pass


async def _send_json(ws: WebSocket, payload: dict) -> None:
    try:
        logger.debug(f"[send] {payload}")
        await ws.send_json(payload)
    except Exception as e:
        logger.debug(f"[send] error: {e=}")


class TranscribeStreamPipeline:
    """
    ASR 流 + 可选纠错；超过 idle_timeout_sec 无新识别内容则发送 closed 并结束。
    共享状态用实例属性维护，避免 nonlocal。
    """

    def __init__(
        self,
        ws: WebSocket,
        audio_stream: AsyncIterator[bytes],
        *,
        effect: bool = False,
        use_llm: bool = False,
        idle_timeout_sec: float = 5.0,
    ) -> None:
        self.ws = ws
        self.audio_stream = audio_stream
        self.effect = effect
        self.idle_timeout_sec = idle_timeout_sec
        self.use_correction = settings.volcengine.ark_valid and use_llm
        self._loop = asyncio.get_running_loop()

        self.current_asr = ""
        self.asr_done = False
        self.last_sent = ""  # 上次已处理的 ASR snap，用于去重
        self.last_sent_text = ""  # 上次实际下发给客户端的文本（纠错后），用于 is_final
        self.stable_history: list[str] = []
        self.last_speech_at: float = self._loop.time()
        self.last_asr_update_at: float = self._loop.time()
        self.idle_timeout_requested = asyncio.Event()

        self._asr_task: asyncio.Task[None] | None = None
        self._corr_task: asyncio.Task[None] | None = None
        self._idle_task: asyncio.Task[None] | None = None

    async def _consume_asr(self) -> None:
        try:
            async for full_text in volcengine.transcribe_volcengine_stream(
                self.audio_stream, effect=self.effect
            ):
                self.current_asr = full_text
                self.last_asr_update_at = self._loop.time()
        finally:
            self.asr_done = True

    async def _send_chunk(self, text: str, snap: str) -> None:
        """发送一段文本并更新 last_sent / last_sent_text / last_speech_at。"""
        await _send_json(self.ws, {"text": text, "is_final": False})
        self.last_sent = snap
        self.last_sent_text = text
        self.last_speech_at = self._loop.time()

    async def _correction_loop(self) -> None:
        while True:
            if not self.idle_timeout_requested.is_set():
                await asyncio.sleep(CORRECTION_WINDOW_SEC)
            snap = self.current_asr
            done_or_closing = self.asr_done or self.idle_timeout_requested.is_set()
            if not snap or snap == self.last_sent:
                if done_or_closing:
                    # 断开前若开启 LLM 且当前有 ASR 内容，做最后一次 LLM 处理
                    if self.use_correction and snap:
                        try:
                            history = (
                                "\n".join(self.stable_history[-3:])
                                if self.stable_history
                                else ""
                            )
                            text = await ark_correction.correct_full(
                                snap, history=history
                            )
                            await self._send_chunk(text, snap)
                        except Exception as e:
                            logger.warning(f"final correction error: {e=}")
                            await self._send_chunk(snap, snap)
                    break
                continue
            try:
                if self.use_correction:
                    history = (
                        "\n".join(self.stable_history[-3:]) if self.stable_history else ""
                    )
                    text = await ark_correction.correct_full(snap, history=history)
                    if self.asr_done:
                        self.stable_history.append(text)
                else:
                    text = snap
                await self._send_chunk(text, snap)
            except Exception as e:
                logger.warning(f"correction error: {e=}")
                await self._send_chunk(snap, snap)
            if self.idle_timeout_requested.is_set() or self.asr_done:
                break
        await _send_json(
            self.ws, {"text": self.last_sent_text or "", "is_final": True}
        )

    async def _idle_check_loop(self) -> None:
        check_interval = min(CHECK_INTERVAL_CAP_SEC, self.idle_timeout_sec)
        while True:
            await asyncio.sleep(check_interval)
            if self._loop.time() - self.last_asr_update_at >= self.idle_timeout_sec:
                logger.info(
                    f"transcribe ws idle timeout (no speech) after {self.idle_timeout_sec}s"
                )
                self.idle_timeout_requested.set()
                if self._corr_task is not None:
                    try:
                        await asyncio.wait_for(
                            asyncio.shield(self._corr_task),
                            timeout=CORR_WAIT_TIMEOUT_SEC,
                        )
                    except asyncio.TimeoutError:
                        self._corr_task.cancel()
                        try:
                            await self._corr_task
                        except asyncio.CancelledError:
                            pass
                await _send_json(
                    self.ws, {"closed": True, "reason": "idle_timeout"}
                )
                if self._asr_task is not None:
                    self._asr_task.cancel()
                return

    async def run(self) -> None:
        """启动 ASR、纠错、空闲检测三个协程并等待结束。"""
        self._asr_task = asyncio.create_task(self._consume_asr())
        self._corr_task = asyncio.create_task(self._correction_loop())
        self._idle_task = asyncio.create_task(self._idle_check_loop())
        try:
            await asyncio.gather(
                self._asr_task, self._corr_task, self._idle_task
            )
        except (asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
            for t in (self._asr_task, self._corr_task, self._idle_task):
                if t is not None:
                    t.cancel()
            await asyncio.gather(
                self._asr_task,
                self._corr_task,
                self._idle_task,
                return_exceptions=True,
            )


@router.websocket("/transcribe/stream")
async def transcribe_stream(
    ws: WebSocket,
    effect: bool = Query(False, description="是否开启效果转写/去口语化"),
    use_llm: bool = Query(False, description="是否启用 LLM 纠错，由后端配置决定"),
    idle_timeout_sec: int | None = Query(
        None, description="无新识别内容超过该秒数则关闭，不传则用服务端配置"
    ),
) -> None:
    """
    豆包流式转写。客户端发送 PCM（16k/16bit/mono），服务端返回
    ``{"text": "当前全文", "is_final": false}``。Ark 配置有效且 use_llm 为 true 时做纠错（use_llm 由后端配置决定）。
    """
    await ws.accept()
    logger.info(
        f"transcribe stream ws connected {settings.volcengine.ark_valid=} {effect=} {use_llm=}"
    )

    if idle_timeout_sec is not None:
        idle_timeout = float(
            min(max(idle_timeout_sec, IDLE_TIMEOUT_MIN), IDLE_TIMEOUT_MAX)
        )
        logger.info(f"transcribe ws idle timeout from client: {idle_timeout}s")
    else:
        idle_timeout = float(settings.transcribe_ws_idle_timeout_sec)
        logger.info(f"transcribe ws idle timeout from config: {idle_timeout}s")
    try:
        pipeline = TranscribeStreamPipeline(
            ws,
            _audio_stream_from_ws(ws),
            effect=effect,
            use_llm=use_llm,
            idle_timeout_sec=idle_timeout,
        )
        await pipeline.run()
    except (WebSocketDisconnect, RuntimeError) as e:
        logger.debug(f"stream ws closed: {e=}")
    except Exception as e:
        logger.warning(f"stream error: {e=}")
        await _send_json(ws, {"text": "", "is_final": True, "error": str(e)})
    finally:
        try:
            await ws.close()
        except Exception:
            pass
