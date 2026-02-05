# byvo

语音转写应用：Flutter 客户端 + FastAPI 后端。

## 项目结构

- `lib/` Flutter 客户端
- `backend/` FastAPI 后端（SenseVoice、豆包转写、SQLite 持久化）

## 后端

使用 uv 作为包管理器。

### 启动

```bash
cd backend
uv sync
uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### 配置

配置使用 YAML 格式，复制 `config/config.yaml.example` 为 `config/config.yaml` 后修改：

```yaml
database_url: sqlite:///./byvo.db
volcengine:
  app_key: ""
  access_key: ""
  resource_id: ""
sensevoice_model_dir: ./models/sensevoice
```

豆包凭证亦可由环境变量 `VOLCENGINE__APP_KEY`、`VOLCENGINE__ACCESS_KEY`、`VOLCENGINE__RESOURCE_ID` 覆盖。

- **SenseVoice 模型**：将 `model.int8.onnx`、`tokens.txt` 放入 `backend/models/sensevoice/`。可从 [sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases) 下载预转换模型。

### API

- `POST /api/v1/transcribe`：multipart/form-data，`audio`（WAV 文件）、`engine`（sensevoice | volcengine）
- `WebSocket /api/v1/transcribe/stream?engine=volcengine`：流式转写，客户端发送 PCM（16k/16bit/mono）二进制，服务端返回 JSON `{ "text": "增量文本", "is_final": false }`
- `GET /health`：健康检查

## 客户端

Flutter 客户端通过 HTTP 调用后端转写。在设置中配置后端地址（默认 `http://10.0.2.2:8000`，适用于 Android 模拟器访问本机）。

- **录制 + 转写**：录制 WAV 后 POST 到后端
- **实时转写**：豆包引擎使用 WebSocket 流式连接，`record.startStream` + WS 推送 PCM，边录边出字，无分块间隙；SenseVoice 使用分块 HTTP

```bash
flutter pub get
flutter run
```
