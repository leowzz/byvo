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
api_base_url: "http://192.168.1.20:8000"

auth:
  api_keys:
    - "replace-with-a-long-random-key"
```

也可通过环境变量覆盖（示例）：

```bash
AUTH__API_KEYS='["replace-with-a-long-random-key"]'
```

豆包凭证仍可由环境变量 `VOLCENGINE__APP_KEY`、`VOLCENGINE__ACCESS_KEY`、`VOLCENGINE__RESOURCE_ID` 覆盖。

### 启动二维码

若配置了：

- `api_base_url`
- `auth.api_keys`

后端启动时会在终端打印：

- `API Base URL`
- `API Key`
- 一个用于客户端扫码填充的二维码

二维码内容格式为：

`byvo://setup?base_url=...&api_key=...`

若 `api_base_url` 或 API key 缺失，则服务正常启动，但会跳过二维码输出。

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

## Docker 部署后端

1. 准备配置文件：

```bash
cp backend/config/config.yaml.example backend/config/config.yaml
```

2. 按需修改 `backend/config/config.yaml`，或使用环境变量覆盖：

```bash
export AUTH__API_KEYS='["replace-with-a-long-random-key"]'
export VOLCENGINE__APP_KEY=...
export VOLCENGINE__ACCESS_KEY=...
export VOLCENGINE__RESOURCE_ID=...
```

3. 启动服务：

```bash
docker compose up -d --build
```

4. 验证健康检查：

```bash
curl http://127.0.0.1:8000/health
```

SQLite 数据默认持久化在 Docker named volume `backend_data`（挂载到容器 `/data`），容器配置文件来自 `backend/config/`。该方案适用于本地开发、Linux x86_64 和 Linux ARM64 环境。

## 客户端

Flutter 客户端在设置中需要同时配置：

- 后端 Base URL
- API Key

在“后端地址配置”弹窗中，可点击“扫码填充”扫描服务端终端二维码，自动回填：

- 后端 Base URL
- API Key

扫码后仍需点击“保存”才会落盘生效。

客户端通过 HTTP 与 WebSocket 调用后端转写。

```bash
flutter pub get
flutter run
```
