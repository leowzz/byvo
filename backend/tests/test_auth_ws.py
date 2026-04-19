import pytest
from fastapi import status
from fastapi import HTTPException
from starlette.websockets import WebSocketDisconnect

from app.auth import require_ws_api_key


def test_stream_rejects_missing_api_key(client):
    with client.websocket_connect("/api/v1/transcribe/stream") as ws:
        with pytest.raises(WebSocketDisconnect) as exc_info:
            ws.receive_json()
    assert exc_info.value.code == status.WS_1008_POLICY_VIOLATION


def test_stream_rejects_invalid_api_key(client):
    with client.websocket_connect(
        "/api/v1/transcribe/stream",
        headers={"X-API-Key": "wrong-key"},
    ) as ws:
        with pytest.raises(WebSocketDisconnect) as exc_info:
            ws.receive_json()
    assert exc_info.value.code == status.WS_1008_POLICY_VIOLATION


@pytest.mark.asyncio
async def test_require_ws_api_key_accepts_then_closes_on_invalid_key():
    class _FakeWebSocket:
        def __init__(self) -> None:
            self.headers = {"X-API-Key": "wrong-key"}
            self.accepted = False
            self.closed_code: int | None = None

        async def accept(self) -> None:
            self.accepted = True

        async def close(self, code: int = 1000, reason: str | None = None) -> None:
            self.closed_code = code

    ws = _FakeWebSocket()

    with pytest.raises(HTTPException) as exc_info:
        await require_ws_api_key(ws)  # type: ignore[arg-type]

    assert ws.accepted is True
    assert ws.closed_code == status.WS_1008_POLICY_VIOLATION
    assert exc_info.value.status_code == status.HTTP_401_UNAUTHORIZED
    assert exc_info.value.detail == "invalid api key"
