import pytest
from fastapi import status
from starlette.websockets import WebSocketDisconnect


def test_stream_rejects_missing_api_key(client):
    with pytest.raises(WebSocketDisconnect) as exc_info:
        with client.websocket_connect("/api/v1/transcribe/stream"):
            pass
    assert exc_info.value.code == status.WS_1008_POLICY_VIOLATION


def test_stream_rejects_invalid_api_key(client):
    with pytest.raises(WebSocketDisconnect) as exc_info:
        with client.websocket_connect(
            "/api/v1/transcribe/stream",
            headers={"X-API-Key": "wrong-key"},
        ):
            pass
    assert exc_info.value.code == status.WS_1008_POLICY_VIOLATION
