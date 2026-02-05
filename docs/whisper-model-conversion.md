# distil-whisper-large-v3-zh：Safetensors → GGML 转换说明

本应用使用 **whisper.cpp** 的 GGML 格式模型，需将 [JiHungLin/distil-whisper-large-v3-zh](https://huggingface.co/JiHungLin/distil-whisper-large-v3-zh)（Safetensors）转为 GGML（`.bin`）。

## 步骤概要

1. **克隆 whisper.cpp 并准备转换脚本**
   - 克隆：`git clone https://github.com/ggml-org/whisper.cpp`
   - 进入 `whisper.cpp/models/`，参考 `convert-h5-to-ggml.py`。Safetensors 需用 `safetensors.torch.load_file` 等做适配，可参考社区 [Safetensors→GGML 方案](https://casadelkrogh.dk/2025/02/whisper.cpp-safetensors-conversion/)。

2. **下载源模型**
   - 从 Hugging Face 下载 JiHungLin/distil-whisper-large-v3-zh 到本地目录（含 `model.safetensors` 等）。

3. **运行转换**
   - 在 whisper.cpp 的 `models/` 目录下运行适配后的转换脚本，指定源模型路径，输出 `ggml-distil-large-v3-zh.bin`（或兼容的 ggml 文件名）。

4. **放入应用**
   - 将得到的 `.bin` 放入本项目的 `assets/models/` 目录，或通过应用内「选择模型文件」指定路径。

完成上述步骤后即可在应用中使用本地 GGML 模型进行转写。
