"""Backend API key authentication helpers."""

from fastapi import Header, HTTPException, WebSocket, status
from loguru import logger

from app.config import settings

API_KEY_HEADER = "X-API-Key"
INVALID_API_KEY_DETAIL = "invalid api key"


def _is_valid_api_key(api_key: str | None) -> bool:
    if not api_key:
        return False
    return api_key.strip() in settings.auth.normalized_api_keys


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if _is_valid_api_key(x_api_key):
        return
    logger.warning("http auth failed: invalid or missing api key")
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=INVALID_API_KEY_DETAIL,
    )


async def require_ws_api_key(ws: WebSocket) -> bool:
    if _is_valid_api_key(ws.headers.get(API_KEY_HEADER)):
        return True
    logger.warning("websocket auth failed: invalid or missing api key")
    await ws.close(code=status.WS_1008_POLICY_VIOLATION, reason=INVALID_API_KEY_DETAIL)
    return False
