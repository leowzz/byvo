from collections.abc import Iterator
from pathlib import Path
import sys
import types

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
if "soundfile" not in sys.modules:
    soundfile_stub = types.ModuleType("soundfile")

    def _not_available(*_args, **_kwargs):
        raise RuntimeError("soundfile is not available in test runtime")

    soundfile_stub.read = _not_available
    sys.modules["soundfile"] = soundfile_stub

from app.config import settings
from app.main import app


@pytest.fixture(autouse=True)
def stub_transcribe_services(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Result:
        text = "ok"
        emotion = None
        event = None
        lang = "zh"

    async def _fake_transcribe(*_args, **_kwargs):
        return _Result()

    async def _fake_stream(*_args, **_kwargs):
        if False:
            yield ""

    monkeypatch.setattr(
        "app.api.v1.transcribe.volcengine.transcribe_volcengine",
        _fake_transcribe,
    )
    monkeypatch.setattr(
        "app.api.v1.transcribe_ws.volcengine.transcribe_volcengine_stream",
        _fake_stream,
    )


@pytest.fixture(autouse=True)
def reset_api_keys() -> Iterator[None]:
    original = list(settings.auth.api_keys)
    settings.auth.api_keys = ["test-key"]
    try:
        yield
    finally:
        settings.auth.api_keys = original


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client
