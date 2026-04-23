# Android Quick Settings Overlay Tile Design

## Goal

在 Android 系统控制中心增加一个 `TileService` 磁贴，允许用户直接开关 byvo 悬浮球。

目标行为：
- 磁贴图标使用应用图标。
- 磁贴标题显示“悬浮球”。
- 点击磁贴可直接开启或关闭悬浮球。
- 如果缺少悬浮窗权限或无障碍授权，不拉起授权页，只提示失败，并保持关闭状态。
- 磁贴状态、应用内开关状态、实际 overlay 状态尽量保持一致。

## Existing Context

当前悬浮球能力由 Flutter 页面通过 `flutter_overlay_window` 控制：
- Flutter 侧持久化键为 `show_floating_ball`
- overlay 显示/关闭由 `FlutterOverlayWindow.showOverlay()` / `closeOverlay()` 完成
- 无障碍状态通过 `byvo/insert_text` channel 查询

当前 Android 原生工程中还没有 `TileService` 入口，也没有独立的原生悬浮球控制器。

## Chosen Approach

采用原生 `TileService` 直接控制悬浮球的启停，并新增一层原生 `FloatingBallController` 统一管理状态。

不采用“磁贴唤起 Flutter 页面再控制”的方案，原因：
- 控制中心点击应尽快响应，不能依赖 Flutter 引擎冷启动
- 权限失败时只需提示，不需要跳转界面
- 原生集中控制更容易保证磁贴状态和持久化一致

## Architecture

新增三个 Android 侧职责单元：

### 1. `FloatingBallController`

职责：
- 读取和写入 `show_floating_ball`
- 判断当前 overlay 是否处于开启状态
- 执行开启和关闭悬浮球
- 检查悬浮窗权限和无障碍状态
- 在状态变化后刷新 quick settings tile

约束：
- 开启失败时必须显式回写关闭状态
- 关闭路径必须幂等；即使 overlay 已不存在，也应把状态纠正为关闭
- 与 Flutter 页面共用同一个 `SharedPreferences` 键，避免双状态源

### 2. `FloatingBallTileService`

职责：
- 在 `onStartListening()` 时根据持久化状态和实际 overlay 状态刷新磁贴 UI
- 在 `onClick()` 时切换悬浮球状态
- 开启失败时只做 `Toast` 提示，不打开授权页面

磁贴显示规则：
- `STATE_ACTIVE`：悬浮球已开启
- `STATE_INACTIVE`：悬浮球已关闭或无法开启
- icon：应用 launcher icon
- label：`悬浮球`

### 3. Manifest registration

职责：
- 注册 `TileService`
- 声明 quick settings tile 所需 intent filter 和权限
- 让系统可在控制中心发现这个磁贴

## Data Flow

### Enable from Quick Settings

1. 用户点击控制中心磁贴
2. `FloatingBallTileService` 调用 `FloatingBallController.enable()`
3. Controller 先检查：
   - overlay permission
   - accessibility enabled
4. 如果任一条件缺失：
   - 返回失败结果和失败原因
   - 写入 `show_floating_ball = false`
   - 刷新 tile 为关闭
   - `TileService` 用 `Toast` 提示失败
5. 如果条件满足：
   - 启动 overlay service
   - 写入 `show_floating_ball = true`
   - 刷新 tile 为开启

### Disable from Quick Settings

1. 用户再次点击磁贴
2. `FloatingBallController.disable()` 关闭 overlay
3. 写入 `show_floating_ball = false`
4. 刷新 tile 为关闭

### App-side Recovery

应用启动后仍沿用现有 Flutter 恢复逻辑：
- 读取 `show_floating_ball`
- 若为开启且当前 overlay 未激活，则尝试恢复显示

这意味着磁贴和应用内开关通过同一持久化键协作。

## Error Handling

缺少权限时不拉起授权页，错误处理如下：

- 缺少无障碍授权：
  - 提示：`无障碍未开启，无法打开悬浮球`
- 缺少悬浮窗权限：
  - 提示：`悬浮窗权限未开启，无法打开悬浮球`
- overlay 启动失败或异常：
  - 提示：`开启悬浮球失败`

无论哪类失败：
- tile 状态都必须回到关闭
- `show_floating_ball` 都必须写回 `false`

## State Consistency Rules

需要遵守以下一致性规则：

1. `show_floating_ball` 是“用户期望状态”的唯一持久化来源。
2. quick settings tile 每次开始监听时，都要用“持久化状态 + 实际 overlay 状态”做一次纠偏。
3. 如果发现持久化为开启但 overlay 实际未运行：
   - tile 可以先显示关闭
   - 不在 `TileService` 内自动重启 overlay
   - 交由应用启动恢复路径处理
4. Tile 点击关闭时，无论 overlay 当前是否活跃，都要把持久化状态改成关闭。

## Testing Strategy

先测试，后实现。

### Native-side logic tests

优先为 `FloatingBallController` 提取可测试逻辑，覆盖：
- 缺少无障碍授权时返回失败并保持关闭
- 缺少悬浮窗权限时返回失败并保持关闭
- 开启成功时写入开启状态
- 关闭时写入关闭状态

如果当前工程不方便直接加 Android 单元测试，则至少保证控制器逻辑足够薄，并由 Dart 侧补回归测试验证共享状态没有被破坏。

### Flutter regression tests

补充/更新 Flutter 回归测试，验证：
- 当原生侧将 `show_floating_ball` 设为 `true` 时，应用重启后仍会恢复“悬浮球已开启”的 UI 状态
- Tile 侧写回 `false` 不会破坏应用内关闭路径

## Implementation Notes

- 复用现有应用图标作为 tile icon，避免新增专用资源
- 原生侧读取 `SharedPreferences` 时，key 名必须保持为 `show_floating_ball`
- 如需主动刷新磁贴，使用 `TileService.requestListeningState(...)`
- 原生侧检查无障碍状态时，复用当前插件判断逻辑或抽取成公共 helper，避免两套判断标准

## Non-Goals

本次不做：
- 从磁贴直接拉起授权设置页
- 在磁贴中展示更复杂的文案或副标题
- 新增第二套独立于 Flutter 的悬浮球状态存储
- 改造 overlay UI 本身
