"""WebSocket 流式转写 API。支持可选 Ark 实时纠错（Typeless 风格）。"""

import asyncio
from collections.abc import AsyncIterator

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from loguru import logger

from app.config import settings
from app.services import ark_correction, volcengine

router = APIRouter()

CORRECTION_WINDOW_SEC = 0.5


async def _audio_stream_from_ws(ws: WebSocket) -> AsyncIterator[bytes]:
    """从 WebSocket 读取二进制 PCM 并 yield。"""
    try:
        while True:
            data = await ws.receive_bytes()
            if data:
                yield data
    except (WebSocketDisconnect, RuntimeError):
        pass


async def _safe_send_json(ws: WebSocket, payload: dict) -> None:
    """发送 JSON，若连接已关闭则忽略，避免 ASGI 'send after close'。"""
    try:
        await ws.send_json(payload)
    except (RuntimeError, WebSocketDisconnect, Exception):
        pass


async def _run_asr_and_correction(
    ws: WebSocket,
    audio_stream: AsyncIterator[bytes],
) -> None:
    """
    ASR 流 + 500ms 窗口纠错：仅当 Ark 配置有效时启用纠错，否则只下发 ASR 全文。
    """
    current_asr = ""
    asr_done = False
    last_sent = ""
    stable_history: list[str] = []

    async def consume_asr() -> None:
        nonlocal current_asr, asr_done
        try:
            async for full_text in volcengine.transcribe_volcengine_stream(audio_stream):
                current_asr = full_text
        finally:
            asr_done = True

    use_correction = settings.volcengine.ark_valid

    async def correction_loop() -> None:
        nonlocal last_sent, stable_history
        while True:
            await asyncio.sleep(CORRECTION_WINDOW_SEC)
            snapshot = current_asr
            if not snapshot:
                if asr_done:
                    break
                continue
            if snapshot == last_sent:
                if asr_done:
                    break
                continue
            try:
                if use_correction:
                    history = "\n".join(stable_history[-3:]) if stable_history else ""
                    corrected = await ark_correction.correct_full(snapshot, history=history)
                    await _safe_send_json(ws, {"text": corrected, "is_final": False})
                    if asr_done:
                        stable_history.append(corrected)
                else:
                    await _safe_send_json(ws, {"text": snapshot, "is_final": False})
                last_sent = snapshot
            except Exception as e:
                logger.warning(f"correction error: {e=}")
                await _safe_send_json(ws, {"text": snapshot, "is_final": False})
                last_sent = snapshot
            if asr_done:
                break

        await _safe_send_json(ws, {"text": last_sent or "", "is_final": True})

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
async def transcribe_stream(ws: WebSocket) -> None:
    """
    豆包流式转写。客户端发送二进制 PCM（16k/16bit/mono），服务端返回
    ``{ "text": "当前全文（ASR 或纠错后）", "is_final": false }``。
    若配置 Ark，则按 500ms 窗口做实时纠错后下发。
    """
    await ws.accept()
    audio_stream = _audio_stream_from_ws(ws)
    logger.info(f"transcribe stream ws connected {settings.volcengine.ark_valid=}")

    try:
        if settings.volcengine.ark_valid:
            await _run_asr_and_correction(ws, audio_stream)
        else:
            async for full_text in volcengine.transcribe_volcengine_stream(audio_stream):
                await _safe_send_json(ws, {"text": full_text, "is_final": False})
            await _safe_send_json(ws, {"text": "", "is_final": True})
    except (WebSocketDisconnect, RuntimeError) as e:
        logger.debug(f"stream ws closed: {e=}")
    except Exception as e:
        logger.warning(f"stream error: {e=}")
        await _safe_send_json(ws, {"text": "", "is_final": True, "error": str(e)})
    finally:
        try:
            await ws.close()
        except Exception:
            pass
