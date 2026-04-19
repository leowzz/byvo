# byvo QR Setup Design

## Background

当前项目已经具备：

- 后端独立部署能力
- 基于 `X-API-Key` 的 HTTP / WebSocket 认证
- Flutter 客户端手动填写后端地址和 API key

本次目标是在此基础上增加一条更轻量的配置分发链路：

- 服务启动时，在终端 stdout 中打印 API 地址、API key 和可扫码二维码
- Flutter 客户端支持一键扫码，将后端地址和 API key 自动回填到设置弹窗

## Scope

本次只覆盖以下范围：

- 后端新增 `api_base_url` 配置项
- 后端启动时输出一份终端可读的二维码配置载荷
- Flutter 客户端新增扫码入口和二维码解析回填
- 为二维码载荷格式和解析逻辑增加测试

本次不做以下内容：

- 不做网页配网页
- 不做自动推断局域网 IP
- 不做多 key 交互选择
- 不做扫码后自动保存配置

## Chosen Approach

采用方案 1：终端 ASCII 二维码 + 客户端扫码回填。

核心原则：

- 服务端二维码内容使用自定义 URI：`byvo://setup?...`
- `api_base_url` 必须显式配置，不做本机地址猜测
- 启动时每次都打印一次二维码和明文摘要
- 客户端扫码后仅回填字段，仍由用户点击“保存”确认

## QR Payload Format

二维码载荷格式固定为：

```text
byvo://setup?base_url=<urlencoded>&api_key=<urlencoded>
```

字段定义：

- `base_url`：客户端后端 Base URL，例如 `http://192.168.1.20:8000`
- `api_key`：服务端要求的 `X-API-Key`

格式约束：

- scheme 必须是 `byvo`
- host 必须是 `setup`
- `base_url` 和 `api_key` 都必须存在且非空

这样客户端能快速判断二维码是否是 byvo 的配置码，并且便于后续扩展额外参数。

## Backend Configuration

后端配置模型新增：

- `api_base_url: str = ""`

配置来源保持现有约定：

- 环境变量优先
- `backend/config/config.yaml`
- 默认值

配置示例：

```yaml
api_base_url: "http://192.168.1.20:8000"

auth:
  api_keys:
    - "replace-with-a-long-random-key"
```

若 `api_base_url` 为空：

- 服务正常启动
- stdout 打印“未配置 api_base_url，跳过二维码输出”
- 不生成二维码

## Backend Startup Output

后端启动时增加一个独立输出模块，例如 `backend/app/boot_output.py`，职责如下：

- 从配置中读取 `api_base_url`
- 从 `settings.auth.normalized_api_keys` 中读取可用 API key
- 组装二维码载荷 URI
- 渲染为终端 ASCII 二维码
- 将信息打印到 stdout

启动输出内容包含：

- `API Base URL: ...`
- `API Key: ...`
- 二维码本体

边界行为：

- 若 `auth.api_keys` 为空，打印明确提示并跳过二维码输出
- 若配置了多个 key，仅使用第一个 key 生成二维码
- 若使用第一个 key，日志中明确说明二维码使用第一个 API key

本次只要求 stdout 输出，不要求写文件或暴露额外 HTTP 页面。

## Flutter Client Flow

在“后端地址配置”弹窗中新增：

- 一个 `扫码填充` 按钮

交互流程：

1. 用户点击 `扫码填充`
2. 进入一个简单扫码页
3. 扫到二维码内容后解析
4. 如果格式有效，回填 `Base URL` 和 `API Key`
5. 返回设置弹窗
6. 用户点击 `保存`

重要约束：

- 扫码成功后不自动保存
- 用户仍可以手动修改字段

## Flutter Parsing Design

客户端应将二维码解析逻辑从 UI 中拆开，例如新增一个 helper：

- `parseByvoSetupUri(String raw)`

返回值至少包含：

- `baseUrl`
- `apiKey`

解析规则：

- 不是 `byvo://setup?...`：视为无效配置码
- 缺少 `base_url` 或 `api_key`：视为不完整配置码
- 成功时返回解析后的字段值

此 helper 应尽量保持与具体扫码控件无关，便于后续支持粘贴导入或测试。

## Flutter Scanning Design

Flutter 增加扫码依赖，例如 `mobile_scanner`。

新增一个小型扫码页，例如：

- `lib/scan/setup_qr_page.dart`

职责如下：

- 打开摄像头扫描二维码
- 只处理首次识别结果
- 将原始字符串返回给调用方

设置弹窗负责：

- 打开扫码页
- 调用解析 helper
- 回填文本框
- 对错误结果显示提示

## Error Handling

### Backend

- `api_base_url` 为空：打印提示，跳过二维码输出
- `auth.api_keys` 为空：打印提示，跳过二维码输出
- 若二维码渲染失败：打印错误，但不影响服务启动

### Flutter

- 扫到非 byvo 配置码：提示“不是有效的 byvo 配置码”
- 缺少字段：提示“配置码不完整”
- 用户取消扫码：静默返回设置弹窗

## Testing Requirements

后端至少需要验证：

- 在给定 `api_base_url` 和 API key 时，能生成正确的 `byvo://setup?...` 字符串
- 当 `api_base_url` 为空时，不生成二维码载荷
- 当 key 列表为空时，不生成二维码载荷

客户端至少需要验证：

- `parseByvoSetupUri` 能正确解析合法 URI
- 非法 scheme / host 会报错
- 缺失 `base_url` 或 `api_key` 会报错

如果扫码页难以做完整 widget 测试，至少要把解析层做成可测试的纯逻辑。

## Acceptance Criteria

- 后端配置新增 `api_base_url`
- 服务启动时在 stdout 打印 API Base URL、API Key 和二维码
- 若 `api_base_url` 或 API key 缺失，服务仍启动但跳过二维码输出并给出提示
- 二维码内容格式为 `byvo://setup?base_url=...&api_key=...`
- Flutter 设置弹窗新增 `扫码填充`
- 客户端扫码后可自动回填 Base URL 和 API Key
- 非法二维码会给出明确错误提示
- 回填后仍需用户点击“保存”

## Files Likely To Change

- `backend/app/config.py`
- `backend/config/config.yaml.example`
- `backend/app/main.py`
- `backend/app/boot_output.py` or equivalent new module
- `backend/pyproject.toml`
- `README.md`
- `pubspec.yaml`
- `lib/main.dart`
- `lib/config/backend_config.dart`
- `lib/scan/setup_qr_page.dart`
- `lib/scan/setup_qr_parser.dart`
- `backend/tests/...`
- `test/...`
