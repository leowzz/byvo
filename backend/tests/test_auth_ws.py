import pytest
from starlette.websockets import WebSocketDisconnect


def test_stream_rejects_missing_api_key(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/api/v1/transcribe/stream"):
            pass


def test_stream_rejects_invalid_api_key(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(
            "/api/v1/transcribe/stream",
            headers={"X-API-Key": "wrong-key"},
        ):
            pass
