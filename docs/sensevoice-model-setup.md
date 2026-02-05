# SenseVoice Small（阿里）模型配置

本应用使用 **Sherpa-ONNX** 运行阿里开源的 **SenseVoice Small**，支持中英日韩粤、情感识别（开心/悲伤等）与环境音（背景音乐、掌声等）。

## 模型下载

**一键配置（推荐）**：在项目根目录执行：

```powershell
.\scripts\download-sensevoice-model.ps1
```

脚本会下载约 230MB 的 tar.bz2、解压并将 **model.int8.onnx**、**tokens.txt** 复制到 **assets/sensevoice/**。

**手动下载**：

1. 下载 Sherpa-ONNX 预转换的 SenseVoice 模型：
   - https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
2. 解压后得到目录，内含 **model.int8.onnx** 与 **tokens.txt**。

## 使用方式

- **方式 A**：将 **model.int8.onnx** 和 **tokens.txt** 放入项目 **assets/sensevoice/** 目录，构建后应用内点击「从 assets 加载」。
- **方式 B**：在应用内点击「选择模型目录（选 model.int8.onnx）」并选择解压目录中的 **model.int8.onnx** 文件（同目录下须有 tokens.txt）。

## 参考

- Sherpa-ONNX SenseVoice 文档：https://k2-fsa.github.io/sherpa/onnx/sense-voice/
- 预训练模型说明：https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html
- 阿里 SenseVoice：https://github.com/FunAudioLLM/SenseVoice
