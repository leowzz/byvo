"""WebSocket 流式转写：豆包 ASR，可选 Ark 纠错。"""

import asyncio
from collections.abc import AsyncIterator

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from loguru import logger

from app.config import settings
from app.services import ark_correction, volcengine

router = APIRouter()
CORRECTION_WINDOW_SEC = 0.5


async def _audio_stream_from_ws(ws: WebSocket) -> AsyncIterator[bytes]:
    """从 WebSocket 读取二进制 PCM。"""
    try:
        while True:
            yield await ws.receive_bytes()
    except (WebSocketDisconnect, RuntimeError):
        pass


async def _send_json(ws: WebSocket, payload: dict) -> None:
    try:
        await ws.send_json(payload)
    except (RuntimeError, WebSocketDisconnect, Exception):
        pass


async def _run_stream_pipeline(
    ws: WebSocket,
    audio_stream: AsyncIterator[bytes],
    *,
    effect: bool = False,
) -> None:
    """
    ASR 流 + 可选纠错：use_correction 时按 500ms 窗口调用 Ark 纠错后下发，否则直接下发 ASR 全文。
    """
    current_asr = ""
    asr_done = False
    last_sent = ""
    stable_history: list[str] = []
    use_correction = settings.volcengine.ark_valid and effect

    async def consume_asr() -> None:
        nonlocal current_asr, asr_done
        try:
            async for full_text in volcengine.transcribe_volcengine_stream(audio_stream, effect=effect):
                current_asr = full_text
        finally:
            asr_done = True

    async def correction_loop() -> None:
        nonlocal last_sent, stable_history
        while True:
            await asyncio.sleep(CORRECTION_WINDOW_SEC)
            snap = current_asr
            if not snap:
                if asr_done:
                    break
                continue
            if snap == last_sent:
                if asr_done:
                    break
                continue
            try:
                if use_correction:
                    history = "\n".join(stable_history[-3:]) if stable_history else ""
                    text = await ark_correction.correct_full(snap, history=history)
                    if asr_done:
                        stable_history.append(text)
                else:
                    text = snap
                await _send_json(ws, {"text": text, "is_final": False})
                last_sent = snap
            except Exception as e:
                logger.warning(f"correction error: {e=}")
                await _send_json(ws, {"text": snap, "is_final": False})
                last_sent = snap
            if asr_done:
                break
        await _send_json(ws, {"text": last_sent or "", "is_final": True})

    asr_task = asyncio.create_task(consume_asr())
    corr_task = asyncio.create_task(correction_loop())
    try:
        await asyncio.gather(asr_task, corr_task)
    except (asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
        asr_task.cancel()
        corr_task.cancel()
        try:
            await asyncio.gather(asr_task, corr_task)
        except (asyncio.CancelledError, Exception):
            pass


@router.websocket("/transcribe/stream")
async def transcribe_stream(
    ws: WebSocket,
    effect: bool = Query(False, description="是否开启效果转写/去口语化"),
) -> None:
    """
    豆包流式转写。客户端发送 PCM（16k/16bit/mono），服务端返回
    ``{"text": "当前全文", "is_final": false}``。Ark 配置有效且 effect 开启时做纠错。
    """
    await ws.accept()
    logger.info(f"transcribe stream ws connected {settings.volcengine.ark_valid=} {effect=}")

    try:
        await _run_stream_pipeline(ws, _audio_stream_from_ws(ws), effect=effect)
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
