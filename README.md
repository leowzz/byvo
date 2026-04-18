# byvo

语音转写应用：Flutter 客户端 + FastAPI 后端。

## 项目结构

- `lib/` Flutter 客户端
- `backend/` FastAPI 后端（豆包转写、可选 Ark 纠错、SQLite 持久化）

## 后端独立部署

后端目录是 `backend/`，可作为独立 FastAPI 服务部署。

### 安装依赖

```bash
cd backend
uv sync --extra dev
```

### 配置

复制 `backend/config/config.yaml.example` 为 `backend/config/config.yaml`，并至少配置：

```yaml
auth:
  api_keys:
    - "replace-with-a-long-random-key"
```

也可通过环境变量覆盖（示例）：

```bash
AUTH__API_KEYS='["replace-with-a-long-random-key"]'
```

豆包凭证仍可由环境变量 `VOLCENGINE__APP_KEY`、`VOLCENGINE__ACCESS_KEY`、`VOLCENGINE__RESOURCE_ID` 覆盖。

### 启动

开发（热重载）：

```bash
cd backend
make run-dev
```

部署/生产：

```bash
cd backend
make run
```

### 认证与健康检查

- `POST /api/v1/transcribe` 和 `WebSocket /api/v1/transcribe/stream` 需要请求头：`X-API-Key: <your-api-key>`
- `GET /health` 不需要认证，可用于探活：

```bash
curl http://127.0.0.1:8000/health
```

## 客户端

Flutter 客户端在设置中需要同时配置：

- 后端 Base URL
- API Key

客户端通过 HTTP 与 WebSocket 调用后端转写。

```bash
flutter pub get
flutter run
```
