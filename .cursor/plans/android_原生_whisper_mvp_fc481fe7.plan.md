---
name: Android 原生 Whisper MVP
overview: 在现有 Flutter 项目 byvo 中，使用 distil-whisper-large-v3-zh 的本地 GGML 文件，通过扩展 whisper_kit 支持 modelPath，在 Android 上实现「选/录 WAV → 本地转写 → 展示」MVP，用于验证效果。
todos:
  - id: model-convert
    content: 完成 JiHungLin/distil-whisper-large-v3-zh 的 Safetensors→GGML 转换，得到 ggml-distil-large-v3-zh.bin
    status: completed
  - id: model-place
    content: 将 .bin 放入 assets/models/ 或实现「选择模型文件」UI，确定应用内模型路径来源
    status: completed
  - id: deps-permissions
    content: pubspec 增加 whisper_kit、file_picker、record；AndroidManifest 增加 RECORD_AUDIO 及选文件权限
    status: completed
  - id: whisper-override
    content: dependency override 引入本地 whisper_kit，在 Whisper 类增加 modelPath 支持并跳过下载、使用该路径转写
    status: completed
  - id: ui-page
    content: 替换 main.dart 为单页 UI：选择 WAV / 录制、模型路径（若用户选择）、loading、转写结果与 segments
    status: completed
  - id: transcribe-call
    content: "集成转写调用 Whisper(modelPath).transcribe(TranscribeRequest(audio, language: zh))，结果展示，可选 isolate/compute"
    status: completed
  - id: assets-copy
    content: 若用 assets 方案，实现首次启动从 assets/models 复制 .bin 到 getApplicationSupportDirectory()
    status: completed
  - id: build-verify
    content: 确认 minSdk≥24、NDK/CMake 可用，真机运行并验证选 WAV/录音→转写→展示
    status: completed
isProject: false
---

# Android 原生运行 Whisper 模型 MVP 计划

## 项目现状

- **byvo** 为 Flutter 应用，Android 为平台之一（[android/](android/) 下为 Kotlin + Flutter 嵌入）。
- 当前无任何语音识别或 Whisper 相关代码；[lib/main.dart](lib/main.dart) 为默认计数器 demo。

## 方案选择

| 方案 | 优点 | 缺点 |
|------|------|------|
| **Flutter 插件 whisper_kit** | 直接集成、API 简单、底层已是 whisper.cpp，适合快速验证 | 仅 Android；模型需下载（约 75MB–1.5GB） |
| 自建 whisper.cpp + JNI + Method Channel | 完全可控、可定制 | 需维护 native 工程与构建，周期长 |
| WhisperKit Android (Argmax/Qualcomm) | 在骁龙设备上性能最佳 | 需单独集成原生库、与 Flutter 通过 Method Channel 对接，集成量更大 |

**推荐**：MVP 以 **whisper_kit** 为主路径，在现有 Flutter 工程内完成「选文件/录音 → 转写 → 展示」闭环，验证 Android 原生 Whisper 效果。若后续要换底层（如 WhisperKit 或自建 JNI），可保留同一套 Flutter API，仅替换实现。

## 技术要点

- **whisper_kit**（[pub.dev](https://pub.dev/packages/whisper_kit)）：基于 whisper.cpp，支持 Tiny/Base/Small/Medium 模型、WAV 文件路径输入、自动下载模型、带时间戳的 segments。
- **音频输入**：插件要求 **WAV（推荐 16kHz, mono, 16-bit PCM）**。MVP 可二选一或都做：

1. **文件选择**：用 `file_picker` 选 WAV（或先选其他格式，后续可加一步“仅支持 WAV”的提示或简单转换）。
2. **录音**：用 `record` 或 `flutter_sound` 等录制成 WAV，保存到临时文件后把路径传给 whisper_kit。

- **权限**：Android 需在 [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) 中声明 `RECORD_AUDIO`（若录音）、`INTERNET`（模型下载）、按需 `READ_EXTERNAL_STORAGE`/`READ_MEDIA_AUDIO`（选文件）。
- **模型**：本次 MVP 使用 **distil-whisper-large-v3-zh**（中文向蒸馏模型）。见下节「使用 distil-whisper-large-v3-zh」的接入方式。

## 使用 distil-whisper-large-v3-zh 模型

- **模型来源**：[JiHungLin/distil-whisper-large-v3-zh](https://huggingface.co/JiHungLin/distil-whisper-large-v3-zh)（Hugging Face，0.8B 参数，F32，Safetensors）。
- **格式差异**：该仓库提供的是 **Safetensors**（Transformers/PyTorch 格式），而 **whisper_kit / whisper.cpp 仅支持 GGML**（`.bin`）。因此不能直接下载该仓库文件使用，需先做 **Safetensors → GGML 转换**。
- **前置步骤：模型转换（本地文件方案前置）**

1. 从 [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 的 `models/` 目录使用或参考转换脚本（如 `convert-h5-to-ggml.py`；Safetensors 需用 `safetensors.torch.load_file` 等做适配，可参考社区 [Safetensors→GGML 方案](https://casadelkrogh.dk/2025/02/whisper.cpp-safetensors-conversion/)）。
2. 将 [JiHungLin/distil-whisper-large-v3-zh](https://huggingface.co/JiHungLin/distil-whisper-large-v3-zh) 下载到本地，运行转换脚本，输出 `ggml-distil-large-v3-zh.bin`（或兼容的 ggml 文件名）。
3. **本地文件方案**：将得到的 `.bin` 放入应用可读路径。可选：**A** 放入项目 `assets/models/`，首次启动时复制到 `getApplicationSupportDirectory()`；**B** 由用户通过文件选择器指定 `.bin` 路径（需在 UI 增加「选择模型文件」）。

- **接入方式：本地 .bin 文件（已选定）**

- **whisper_kit 限制**：主 API 仅支持枚举 + 下载，不暴露「按路径加载」。采用 **dependency override** 扩展 whisper_kit，在 `Whisper` 上支持传入 **模型文件路径**。
- **实现要点**：

1. 用 **path dependency** 或 **dependency override** 引用本地 fork/拷贝的 whisper_kit 包。
2. 在 `Whisper` 类增加可选参数 `String? modelPath`（或工厂方法 `Whisper.fromPath(String modelPath)`）。当 `modelPath != null` 时，`_initModel()` 跳过下载，转写请求中使用的模型路径用 `modelPath!` 而非 `model.getPath(modelDir)`。
3. 在 [lib/main.dart](lib/main.dart) 等处：若模型来自 assets，先复制到 `getApplicationSupportDirectory()` 得到 `pathToBin`；若来自用户选择，直接使用选中路径。构造 `Whisper(model: WhisperModel.none, modelPath: pathToBin)`（或扩展后的工厂），再调用 `transcribe(TranscribeRequest(audio: audioPath, language: 'zh'))`。

- **转写参数**：`TranscribeRequest(audio: path, language: 'zh')`（或 `'auto'`），其它与现计划一致。

## 实现步骤

0. **模型文件（本地）**

- 完成 Safetensors→GGML 转换，得到 `ggml-distil-large-v3-zh.bin`。
- 二选一：**A** 放入 `assets/models/`，在应用首次启动时复制到 `getApplicationSupportDirectory()` 并记录路径；**B** 在 UI 提供「选择模型文件」，由用户指定 `.bin` 路径。

1. **依赖与权限**

- 在 [pubspec.yaml](pubspec.yaml) 增加：`whisper_kit: ^0.3.0`（或 path override 指向扩展了 `modelPath` 的本地包）；若做录音再加 `record`（或 `flutter_sound`）；选文件加 `file_picker`。
- 在 [AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) 的 `<manifest>` 下添加 `RECORD_AUDIO`、选文件所需权限（`READ_EXTERNAL_STORAGE`/`READ_MEDIA_AUDIO` 等）。本地模型不需 `INTERNET`（若不做联网下载）。

2. **扩展 whisper_kit 支持本地模型路径**

- 通过 **dependency override** 使用本地 fork/拷贝的 whisper_kit。
- 在 `Whisper` 类增加可选参数 `modelPath`（或工厂 `Whisper.fromPath(modelPath)`）；当 `modelPath != null` 时跳过 `_initModel()` 下载，在 `_request`/转写时使用 `modelPath!` 作为模型路径（需修改内部传参，如 `TranscribeRequestDto.fromTranscribeRequest(..., modelPath: modelPath ?? model.getPath(modelDir))` 或等价逻辑）。

3. **最小 UI（验证用）**

- 替换 [lib/main.dart](lib/main.dart) 的 demo 为单页：按钮「选择 WAV 文件」和/或「录制并转写」；显示当前文件/录音状态、转写中 loading、转写结果全文 + 可选 segments。
- 选文件：`file_picker` → path → whisper_kit；录音：权限 → 临时 WAV → 同上。若采用「选择模型文件」方案，增加按钮与状态展示模型路径。

4. **转写调用（本地 distil-whisper-large-v3-zh）**

- 使用扩展后的 API：`Whisper(model: WhisperModel.none, modelPath: pathToBin)` 或 `Whisper.fromPath(pathToBin)`；`pathToBin` 来自 assets 复制或用户选择。
- `whisper.transcribe(TranscribeRequest(audio: audioPath, language: 'zh'))`；结果取 `WhisperTranscribeResponse.text` 与 `segments` 展示。转写建议放在 isolate/compute 中，避免阻塞 UI。

5. **构建与验证**

- 确认 NDK/CMake 可用；[android/app/build.gradle](android/app/build.gradle) 的 `minSdk` 建议 ≥24。
- 真机运行 `flutter run`（Android），确保模型 `.bin` 已就位，选一段 WAV 或录几秒，确认能完成转写并看到文本。

## 可选后续（不纳入本次 MVP）

- 非 WAV 格式：在 Dart 侧用 `ffmpeg_kit_flutter` 等转成 WAV 再送入；或仅在 UI 上限制「仅支持 WAV」。
- 换用 WhisperKit Android 或自建 whisper.cpp JNI：通过 Platform Channel 在 Kotlin 侧调用，Flutter 侧保持「路径 in → 文本/segments out」的接口不变。

## 风险与注意

- **设备**：distil-large-v3 级模型约 756M 参数（ggml 约 1.5GB 量级），低端机或 4GB 以下内存可能较慢或 OOM，建议在中高配 Android 真机上验证。
- **首次运行**：使用本地 .bin，无需为模型联网；需提前完成 Safetensors→GGML 转换并将 `.bin` 放入 assets 或由用户选择路径。
- **音频格式**：非 16kHz mono WAV 可能影响效果，文档建议按此格式录制或转换。

## 小结

采用 **本地模型文件** 方案：先完成 JiHungLin/distil-whisper-large-v3-zh 的 Safetensors→GGML 转换，将 `.bin` 放入 assets 或由用户选择；通过 **dependency override** 扩展 whisper_kit 支持 `modelPath`，在 byvo 中用「选/录 WAV → 本地 Whisper 转写 → 展示」跑通 MVP，无需为模型联网、无需在本阶段自建 JNI 工程。