# byvo Backend Deploy And API Key Auth Design

## Background

`byvo` 目前是 Flutter 客户端加仓库内 `backend/` FastAPI 服务的结构，但后端仍偏开发态使用：

- README 只覆盖本地启动，没有清晰的独立部署说明
- Flutter 允许用户配置后端地址，但没有认证机制
- `POST /api/v1/transcribe` 和 `WebSocket /api/v1/transcribe/stream` 目前都可被任意客户端直接调用

目标是在不引入账号体系的前提下，把后端整理成可以独立部署的版本，并给客户端到后端的连接加上基于 API key 的认证。

## Scope

本次只覆盖以下范围：

- 整理 `backend/` 使其具备明确的独立部署入口和文档
- 后端新增基于固定 API key 的认证
- Flutter 新增 API key 配置并在 HTTP/WS 请求中透传
- 保持现有转写业务接口和转写行为基本不变

本次不做以下内容：

- 不引入账号密码、登录、刷新 token 或用户体系
- 不实现后台管理界面
- 不增加数据库级的 key 管理
- 不做额外应用层加密

## Chosen Approach

采用方案 1：静态 API key 认证。

设计约束如下：

- 后端从环境变量或配置文件中读取一个或多个固定 API key
- Flutter App 允许用户任意填写后端地址和端口，同时填写对应的 API key
- HTTP 和 WebSocket 都统一通过请求头 `X-API-Key` 传递凭据
- 任意受保护接口在缺失或错误 key 时必须拒绝访问
- `/health` 保持匿名访问，供探活和反向代理使用

## Configuration Design

### Backend

在 `backend/app/config.py` 的配置模型中新增认证配置：

- 新增 `auth` 配置节点
- `auth.api_keys` 为字符串列表
- 列表中任意一个 key 命中即视为认证通过

配置来源遵循现有优先级：

- 环境变量优先
- `backend/config/config.yaml`
- 默认值

配置示例结构如下：

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

环境变量需要支持部署场景下覆盖配置文件。实现可以接受以下任一种稳定方式：

- 直接通过 Pydantic settings 的嵌套环境变量映射读取
- 或增加一个专门的字符串环境变量，再在应用内解析为 key 列表

要求是最终部署文档里必须给出明确的环境变量示例。

### Flutter

Flutter 本地配置新增一个 API key 持久化字段：

- 与后端 URL 一起保存在 `SharedPreferences`
- 设置弹窗中允许用户编辑
- 本地不内置固定 key

## Authentication Flow

### Protected Endpoints

以下接口改为受保护：

- `POST /api/v1/transcribe`
- `WebSocket /api/v1/transcribe/stream`

以下接口保持匿名：

- `GET /health`

### HTTP

客户端上传音频时必须携带：

```http
X-API-Key: <key>
```

服务端行为：

- 缺失 key 返回 `401`
- key 不匹配返回 `401`
- 响应体使用清晰错误信息，例如 `{"detail": "invalid api key"}`

### WebSocket

客户端建立 WebSocket 连接时必须携带：

```http
X-API-Key: <key>
```

服务端在进入转写逻辑前完成校验：

- 认证失败时拒绝连接
- 未认证连接不能进入音频流消费或豆包调用流程

实现上应优先在握手阶段或 `accept` 前完成校验；如果框架行为受限，至少要保证：

- 连接建立后立即关闭
- 返回明确的关闭原因
- 不执行任何转写业务逻辑

## Backend Architecture Changes

新增一个独立认证模块，例如 `backend/app/auth.py`，职责如下：

- 读取当前配置中的有效 API key 集合
- 提供 HTTP 依赖校验函数
- 提供 WebSocket 校验函数
- 统一生成认证失败错误

接口文件 `transcribe.py` 和 `transcribe_ws.py` 只负责接入该模块，不内联散乱的认证判断。

后端部署层面的整理原则如下：

- 保持 `backend/` 作为独立服务目录
- 明确区分开发态和部署态启动命令
- 继续保留现有 FastAPI 结构，不做无关重构
- README 和 `backend/Makefile` 明确写出独立部署所需命令

## Client Changes

Flutter 端改动包含：

- `backend_config.dart` 增加 API key 的读取与保存
- 设置弹窗增加 API key 输入框
- `BackendTranscriptionEngine` 发起 multipart POST 时加入 `X-API-Key`
- `RealtimeStreamEngine` 建立 WebSocket 时加入 `X-API-Key`

客户端行为约束：

- 若用户未填写 API key，则本地直接提示配置缺失，不发请求
- 若服务端返回 `401` 或 WebSocket 因认证失败关闭，应尽可能向用户显示为认证错误，而不是通用网络错误

## Deployment Model

后端需要具备“单独部署”所需的最小说明：

- 安装依赖
- 准备配置文件或环境变量
- 启动命令
- 健康检查方式

部署命令分为两类：

- 开发态：带 `--reload`
- 部署态：不带 `--reload`

如果现有代码把 `reload=True` 写死在程序化入口中，需要调整为更适合生产启动的方式，避免误导使用者。

## Error Handling

服务端：

- 未配置任何 API key 时，受保护接口默认拒绝访问
- 日志中应能看出当前认证未配置或认证失败，但不得打印完整明文 key

客户端：

- API key 为空时，不发起 HTTP/WS 请求
- 认证失败时向上抛出可识别错误信息

## Testing Requirements

需要补充覆盖以下行为的测试，优先放在后端：

- HTTP 在缺失 key 时返回 `401`
- HTTP 在错误 key 时返回 `401`
- HTTP 在正确 key 时正常访问
- WebSocket 在缺失 key 时拒绝连接
- WebSocket 在错误 key 时拒绝连接

客户端至少需要验证：

- API key 能正确保存和读取
- 请求头会被加入 HTTP 和 WebSocket 连接

## Acceptance Criteria

- `backend/` 可以作为独立服务目录部署，文档和命令清晰
- 服务端支持从配置文件或环境变量读取一个或多个固定 API key
- `POST /api/v1/transcribe` 必须校验 `X-API-Key`
- `WebSocket /api/v1/transcribe/stream` 必须校验 `X-API-Key`
- `/health` 仍可匿名访问
- Flutter 设置页允许用户配置后端地址和 API key
- Flutter 发起 HTTP 和 WebSocket 请求时都带上 `X-API-Key`
- 缺失或错误 key 时，服务端拒绝访问，客户端能感知认证失败

## Files Likely To Change

- `backend/app/config.py`
- `backend/config/config.yaml.example`
- `backend/app/main.py`
- `backend/app/api/v1/transcribe.py`
- `backend/app/api/v1/transcribe_ws.py`
- `backend/app/auth.py` or equivalent new module
- `backend/Makefile`
- `README.md`
- `lib/config/backend_config.dart`
- `lib/transcription/backend_engine.dart`
- `lib/transcription/realtime_stream_engine.dart`
- `lib/main.dart`
