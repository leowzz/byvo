# Backend API Key Auth And Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `backend/` deployable as a standalone FastAPI service and require `X-API-Key` authentication for Flutter clients using both HTTP and WebSocket transcription endpoints.

**Architecture:** Add a focused backend auth module that loads one or more static API keys from config or env, then reuse it from both the HTTP and WebSocket entrypoints. Extend Flutter local settings to store `backend_url` and `api_key`, attach the key to both request types, and surface config/auth failures clearly without changing the transcription protocol.

**Tech Stack:** FastAPI, Pydantic Settings, pytest, Flutter, SharedPreferences, `http`, `web_socket_channel`

---

## File Structure

- Create: `backend/app/auth.py`
- Create: `backend/tests/conftest.py`
- Create: `backend/tests/test_auth_http.py`
- Create: `backend/tests/test_auth_ws.py`
- Create: `test/backend_config_test.dart`
- Modify: `backend/app/config.py`
- Modify: `backend/config/config.yaml.example`
- Modify: `backend/app/api/v1/transcribe.py`
- Modify: `backend/app/api/v1/transcribe_ws.py`
- Modify: `backend/app/main.py`
- Modify: `backend/pyproject.toml`
- Modify: `backend/Makefile`
- Modify: `README.md`
- Modify: `lib/config/backend_config.dart`
- Modify: `lib/transcription/backend_engine.dart`
- Modify: `lib/transcription/realtime_stream_engine.dart`
- Modify: `lib/main.dart`

### Task 1: Backend Auth Configuration And Red Tests

**Files:**
- Create: `backend/tests/conftest.py`
- Create: `backend/tests/test_auth_http.py`
- Create: `backend/tests/test_auth_ws.py`
- Modify: `backend/app/config.py`
- Modify: `backend/pyproject.toml`

- [ ] **Step 1: Add backend test dependencies and test app fixtures**

Update `backend/pyproject.toml` to include the test client stack:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=7.0",
    "httpx>=0.27.0",
]
```

Create `backend/tests/conftest.py`:

```python
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app


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
```

- [ ] **Step 2: Write the failing HTTP auth tests**

Create `backend/tests/test_auth_http.py`:

```python
from io import BytesIO


def _wav_file() -> tuple[str, BytesIO, str]:
    return ("sample.wav", BytesIO(b"RIFFdemoWAVEfmt "), "audio/wav")


def test_transcribe_rejects_missing_api_key(client):
    response = client.post("/api/v1/transcribe", files={"audio": _wav_file()})

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid api key"}


def test_transcribe_rejects_invalid_api_key(client):
    response = client.post(
        "/api/v1/transcribe",
        files={"audio": _wav_file()},
        headers={"X-API-Key": "wrong-key"},
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid api key"}
```

- [ ] **Step 3: Write the failing WebSocket auth tests**

Create `backend/tests/test_auth_ws.py`:

```python
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
```

- [ ] **Step 4: Add auth config model in `backend/app/config.py`**

Extend config with a dedicated auth section:

```python
class AuthConfig(BaseModel):
    """静态 API key 认证配置。"""

    api_keys: list[str] = Field(default_factory=list, description="允许访问后端的 API keys")

    @property
    def normalized_api_keys(self) -> list[str]:
        return [key.strip() for key in self.api_keys if key.strip()]


class Settings(BaseSettings):
    """应用配置，优先级：环境变量 > config.yaml > 默认值。"""

    model_config = SettingsConfigDict(
        extra="ignore",
        env_nested_delimiter="__",
    )

    database_url: str = Field(default="sqlite:///./byvo.db")
    auth: AuthConfig = Field(default_factory=AuthConfig)
    volcengine: VolcengineConfig = Field(default_factory=VolcengineConfig)
    transcribe_ws_idle_timeout_sec: int = Field(default=5, description="实时转写：无新识别内容超过该秒数则自动关闭连接")
```

- [ ] **Step 5: Run backend auth tests to verify they fail for the right reason**

Run:

```bash
cd backend
uv run pytest tests/test_auth_http.py tests/test_auth_ws.py -v
```

Expected:

```text
FAILED tests/test_auth_http.py::test_transcribe_rejects_missing_api_key
FAILED tests/test_auth_http.py::test_transcribe_rejects_invalid_api_key
FAILED tests/test_auth_ws.py::test_stream_rejects_missing_api_key
FAILED tests/test_auth_ws.py::test_stream_rejects_invalid_api_key
```

Failure reason should be auth not implemented yet, not import errors.

- [ ] **Step 6: Commit the red test scaffolding**

```bash
git add backend/pyproject.toml backend/app/config.py backend/tests/conftest.py backend/tests/test_auth_http.py backend/tests/test_auth_ws.py
git commit -m "test: add backend auth coverage"
```

### Task 2: Implement Backend API Key Authentication

**Files:**
- Create: `backend/app/auth.py`
- Modify: `backend/app/api/v1/transcribe.py`
- Modify: `backend/app/api/v1/transcribe_ws.py`
- Modify: `backend/config/config.yaml.example`
- Test: `backend/tests/test_auth_http.py`
- Test: `backend/tests/test_auth_ws.py`

- [ ] **Step 1: Write the minimal auth module**

Create `backend/app/auth.py`:

```python
from fastapi import Header, HTTPException, WebSocket, status
from loguru import logger

from app.config import settings

API_KEY_HEADER = "X-API-Key"
INVALID_API_KEY_DETAIL = "invalid api key"


def _is_valid_api_key(api_key: str | None) -> bool:
    if not api_key:
        return False
    return api_key in settings.auth.normalized_api_keys


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if _is_valid_api_key(x_api_key):
        return
    logger.warning("http auth failed")
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=INVALID_API_KEY_DETAIL,
    )


async def require_ws_api_key(ws: WebSocket) -> None:
    api_key = ws.headers.get(API_KEY_HEADER)
    if _is_valid_api_key(api_key):
        return
    logger.warning("websocket auth failed")
    await ws.close(code=status.WS_1008_POLICY_VIOLATION)
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=INVALID_API_KEY_DETAIL,
    )
```

- [ ] **Step 2: Protect the HTTP endpoint**

Modify `backend/app/api/v1/transcribe.py` imports and signature:

```python
from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile

from app.auth import require_api_key
```

```python
@router.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(
    _: None = Depends(require_api_key),
    audio: UploadFile = File(...),
    effect: bool = Query(False, description="是否开启效果转写/去口语化（语义顺滑）"),
    use_llm: bool = Query(False, description="是否启用 LLM 纠错，由后端配置决定"),
    db: Session = Depends(get_db),
) -> TranscribeResponse:
```

- [ ] **Step 3: Protect the WebSocket endpoint before the pipeline runs**

Modify `backend/app/api/v1/transcribe_ws.py` imports and connection flow:

```python
from fastapi import APIRouter, HTTPException, Query, WebSocket, WebSocketDisconnect

from app.auth import require_ws_api_key
```

```python
@router.websocket("/transcribe/stream")
async def transcribe_stream(
    ws: WebSocket,
    effect: bool = Query(False, description="是否开启效果转写/去口语化"),
    use_llm: bool = Query(False, description="是否启用 LLM 纠错，由后端配置决定"),
    idle_timeout_sec: int | None = Query(
        None, description="无新识别内容超过该秒数则关闭，不传则用服务端配置"
    ),
) -> None:
    try:
        await require_ws_api_key(ws)
        await ws.accept()
    except HTTPException:
        return
```

Do not call `await ws.accept()` before the auth check.

- [ ] **Step 4: Document auth config defaults**

Modify `backend/config/config.yaml.example`:

```yaml
database_url: sqlite:///./byvo.db

auth:
  api_keys:
    - "replace-with-a-long-random-key"

volcengine:
  app_key: ""
  access_key: ""
  resource_id: "volc.seedasr.sauc.duration"
  ark_api_key: ""
  ark_model_id: "doubao-seed-1-8-251228"
```

- [ ] **Step 5: Run the focused backend tests to verify they pass**

Run:

```bash
cd backend
uv run pytest tests/test_auth_http.py tests/test_auth_ws.py -v
```

Expected:

```text
PASSED tests/test_auth_http.py::test_transcribe_rejects_missing_api_key
PASSED tests/test_auth_http.py::test_transcribe_rejects_invalid_api_key
PASSED tests/test_auth_ws.py::test_stream_rejects_missing_api_key
PASSED tests/test_auth_ws.py::test_stream_rejects_invalid_api_key
```

- [ ] **Step 6: Add one green-path backend test and make it pass**

Append to `backend/tests/test_auth_http.py`:

```python
def test_transcribe_accepts_valid_api_key(client, monkeypatch):
    from app.api.v1 import transcribe as transcribe_module

    monkeypatch.setattr(
        transcribe_module.volcengine,
        "transcribe_volcengine",
        lambda *args, **kwargs: type(
            "Result",
            (),
            {"text": "ok", "emotion": None, "event": None, "lang": "zh"},
        )(),
    )

    response = client.post(
        "/api/v1/transcribe",
        files={"audio": _wav_file()},
        headers={"X-API-Key": "test-key"},
    )

    assert response.status_code == 200
    assert response.json()["text"] == "ok"
```
Run:

```bash
cd backend
uv run pytest tests/test_auth_http.py::test_transcribe_accepts_valid_api_key -v
```

Expected:

```text
PASSED tests/test_auth_http.py::test_transcribe_accepts_valid_api_key
```

- [ ] **Step 7: Commit the backend auth implementation**

```bash
git add backend/app/auth.py backend/app/api/v1/transcribe.py backend/app/api/v1/transcribe_ws.py backend/config/config.yaml.example backend/tests/test_auth_http.py backend/tests/test_auth_ws.py
git commit -m "feat: require api key for backend transcription"
```

### Task 3: Flutter API Key Configuration And Client Requests

**Files:**
- Create: `test/backend_config_test.dart`
- Modify: `lib/config/backend_config.dart`
- Modify: `lib/transcription/backend_engine.dart`
- Modify: `lib/transcription/realtime_stream_engine.dart`
- Modify: `lib/main.dart`
- Test: `test/backend_config_test.dart`

- [ ] **Step 1: Write the failing local config tests**

Create `test/backend_config_test.dart`:

```dart
import 'package:byvo/config/backend_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loadBackendApiKey returns empty by default', () async {
    expect(await loadBackendApiKey(), '');
  });

  test('saveBackendApiKey persists the value', () async {
    await saveBackendApiKey('demo-key');

    expect(await loadBackendApiKey(), 'demo-key');
  });
}
```

- [ ] **Step 2: Run the new Dart config tests and verify red**

Run:

```bash
flutter test test/backend_config_test.dart
```

Expected:

```text
Error: Method not found: 'loadBackendApiKey'
```

- [ ] **Step 3: Implement API key storage helpers**

Modify `lib/config/backend_config.dart`:

```dart
const String _keyBackendUrl = 'backend_url';
const String _keyBackendApiKey = 'backend_api_key';

const String kDefaultBackendUrl = '';

Future<String> loadBackendApiKey() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_keyBackendApiKey) ?? '';
}

Future<void> saveBackendApiKey(String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_keyBackendApiKey, value);
}
```

- [ ] **Step 4: Attach `X-API-Key` to HTTP requests and fail fast when missing**

Modify `lib/transcription/backend_engine.dart`:

```dart
final apiKey = await loadBackendApiKey();
if (apiKey.trim().isEmpty) {
  throw StateError('请先配置 API Key');
}

final request = http.MultipartRequest('POST', uri)
  ..headers['X-API-Key'] = apiKey.trim()
  ..files.add(await http.MultipartFile.fromPath('audio', audioPath));
```

- [ ] **Step 5: Attach `X-API-Key` to WebSocket requests and surface auth errors**

Modify `lib/transcription/realtime_stream_engine.dart` to use `dart:io` `WebSocket.connect` so headers can be sent:

```dart
import 'dart:io';
```

```dart
final apiKey = await loadBackendApiKey();
if (apiKey.trim().isEmpty) {
  throw StateError('请先配置 API Key');
}

final socket = await WebSocket.connect(
  uri.toString(),
  headers: <String, dynamic>{'X-API-Key': apiKey.trim()},
);
_channel = WebSocketChannel.fromSocket(socket);
```

When the socket connect throws an auth-related handshake failure, rethrow a clearer message:

```dart
} on WebSocketException catch (e) {
  throw StateError('实时转写认证失败: $e');
}
```

- [ ] **Step 6: Extend the settings dialog with API key storage**

Modify `_BackendSettingsDialogState` in `lib/main.dart`:

```dart
late final TextEditingController _urlController;
late final TextEditingController _apiKeyController;
```

```dart
@override
void initState() {
  super.initState();
  _urlController = TextEditingController();
  _apiKeyController = TextEditingController();
  loadBackendUrl().then((String url) {
    if (mounted) _urlController.text = url;
  });
  loadBackendApiKey().then((String key) {
    if (mounted) _apiKeyController.text = key;
  });
}
```

```dart
TextField(
  controller: _apiKeyController,
  decoration: const InputDecoration(
    labelText: 'API Key',
    hintText: '输入服务端要求的 X-API-Key',
  ),
  obscureText: true,
)
```

```dart
await saveBackendUrl(_urlController.text.trim());
await saveBackendApiKey(_apiKeyController.text.trim());
```

- [ ] **Step 7: Run Flutter tests to verify the config path stays green**

Run:

```bash
flutter test test/backend_config_test.dart
```

Expected:

```text
All tests passed
```

- [ ] **Step 8: Commit the Flutter client changes**

```bash
git add lib/config/backend_config.dart lib/transcription/backend_engine.dart lib/transcription/realtime_stream_engine.dart lib/main.dart test/backend_config_test.dart
git commit -m "feat: add client api key configuration"
```

### Task 4: Deployable Backend Entry, Docs, And Final Verification

**Files:**
- Modify: `backend/app/main.py`
- Modify: `backend/Makefile`
- Modify: `README.md`
- Test: `backend/tests/test_auth_http.py`
- Test: `backend/tests/test_auth_ws.py`
- Test: `test/backend_config_test.dart`

- [ ] **Step 1: Remove production-hostile defaults from the backend app entry**

Modify `backend/app/main.py` so programmatic startup does not force dev reload:

```python
def main() -> None:
    """启动 uvicorn。"""
    _setup_loguru()
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
    )
```

Keep `make run-dev` as the explicit reload path.

- [ ] **Step 2: Tighten the backend Makefile for standalone deployment**

Modify `backend/Makefile` comments and defaults:

```make
# Backend 常用命令 (uv)

.PHONY: sync run run-dev test clean

sync:
	uv sync --extra dev

run:
	uv run uvicorn app.main:app --host 0.0.0.0 --port 8000

run-dev:
	uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:
	uv run pytest -v

.DEFAULT_GOAL := run
```

- [ ] **Step 3: Update README with standalone deploy and auth instructions**

Replace the backend and client sections in `README.md` with content like:

```md
## 后端独立部署

后端目录为 `backend/`，可以单独部署。

安装依赖：
`cd backend && uv sync --extra dev`

配置：
复制 `config/config.yaml.example` 为 `config/config.yaml`，并设置：
`auth.api_keys: ["replace-with-a-long-random-key"]`

也可以通过环境变量覆盖：
`AUTH__API_KEYS='["replace-with-a-long-random-key"]'`

启动：
开发使用 `make run-dev`
部署使用 `make run`

认证：
受保护接口要求请求头 `X-API-Key: <your-api-key>`
`GET /health` 无需认证

## 客户端

Flutter 客户端需要在设置里同时填写：
- 后端 Base URL
- API Key
```

- [ ] **Step 4: Run backend verification**

Run:

```bash
cd backend
uv run pytest -v
```

Expected:

```text
PASSED tests/test_auth_http.py::test_transcribe_rejects_missing_api_key
PASSED tests/test_auth_http.py::test_transcribe_rejects_invalid_api_key
PASSED tests/test_auth_http.py::test_transcribe_accepts_valid_api_key
PASSED tests/test_auth_ws.py::test_stream_rejects_missing_api_key
PASSED tests/test_auth_ws.py::test_stream_rejects_invalid_api_key
```

- [ ] **Step 5: Run Flutter verification**

Run:

```bash
flutter test test/backend_config_test.dart
```

Expected:

```text
All tests passed
```

- [ ] **Step 6: Smoke-check the standalone backend startup**

Run:

```bash
cd backend
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Expected startup log includes:

```text
byvo backend started
Uvicorn running on http://127.0.0.1:8000
```

Then in another shell:

```bash
curl http://127.0.0.1:8000/health
```

Expected:

```json
{"status":"ok"}
```

- [ ] **Step 7: Commit docs and deploy entry cleanup**

```bash
git add backend/app/main.py backend/Makefile README.md
git commit -m "docs: document backend deployment and auth"
```

## Self-Review

- Spec coverage:
  - Backend standalone deployment is covered by Task 4.
  - Static API key config from YAML/env is covered by Tasks 1 and 2.
  - HTTP and WebSocket auth are covered by Tasks 1 and 2.
  - Flutter backend URL plus API key config is covered by Task 3.
  - Auth failure handling is covered by Tasks 2 and 3.
- Placeholder scan:
  - No `TODO`, `TBD`, or “similar to previous task” shortcuts remain.
  - Each test and command is concrete.
- Type consistency:
  - Shared names are `auth.api_keys`, `normalized_api_keys`, `loadBackendApiKey`, `saveBackendApiKey`, and `X-API-Key`.
