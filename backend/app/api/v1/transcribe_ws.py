"""WebSocket 流式转写 API。"""

from collections.abc import AsyncIterator

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from loguru import logger

from app.services import volcengine

router = APIRouter()


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


@router.websocket("/transcribe/stream")
async def transcribe_stream(
    ws: WebSocket,
    engine: str = Query("volcengine", description="仅支持 volcengine"),
) -> None:
    """
    WebSocket 流式转写。

    客户端发送二进制 PCM（16k/16bit/mono），服务端返回 JSON
    ``{ "text": "增量文本", "is_final": false }``。
    """
    if engine != "volcengine":
        await ws.close(code=4000, reason=f"不支持的引擎: {engine}")
        return

    await ws.accept()
    logger.info("transcribe stream ws connected")

    try:
        async for incremental in volcengine.transcribe_volcengine_stream(
            _audio_stream_from_ws(ws),
        ):
            if incremental:
                await _safe_send_json(ws, {"text": incremental, "is_final": False})
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
