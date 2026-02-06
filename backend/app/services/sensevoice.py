"""SenseVoice（Sherpa-ONNX）本地推理服务。"""

from pathlib import Path

import soundfile as sf
from loguru import logger

from app.config import BASE_DIR, settings
from app.schemas.transcription import TranscribeResult


def _extract_result(result: object) -> TranscribeResult:
    """从 sherpa_onnx 的 result（对象或 dict）提取 text/emotion/event/lang。"""
    def opt(s: str | None) -> str | None:
        return (s.strip() or None) if s else None

    if hasattr(result, "text"):
        text = result.text or ""
        emotion = opt(getattr(result, "emotion", None) or "")
        event = opt(getattr(result, "event", None) or "")
        lang = opt(getattr(result, "lang", None) or "")
    elif isinstance(result, dict):
        text = result.get("text", "") or ""
        emotion = opt(result.get("emotion"))
        event = opt(result.get("event"))
        lang = opt(result.get("lang"))
    else:
        text = str(result) if result else ""
        emotion = event = lang = None
    return TranscribeResult(text=text, emotion=emotion, event=event, lang=lang)


def transcribe_sensevoice(audio_path: str | Path) -> TranscribeResult:
    """使用 SenseVoice 转写音频。"""
    import sherpa_onnx  # 延迟导入，避免启动时 DLL 加载失败

    model_dir = BASE_DIR / Path(settings.sensevoice_model_dir)
    model_path = model_dir / "model.int8.onnx"
    tokens_path = model_dir / "tokens.txt"

    if not model_path.exists() or not tokens_path.exists():
        raise FileNotFoundError(
            f"SenseVoice 模型未找到，请将 model.int8.onnx 和 tokens.txt 放入 {model_dir}"
        )

    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=str(model_path),
        tokens=str(tokens_path),
        use_itn=True,
        debug=False,
        num_threads=2,
    )
    stream = recognizer.create_stream()

    audio, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=True)
    if audio.ndim == 2:
        audio = audio[:, 0]

    stream.accept_waveform(sample_rate, audio)
    recognizer.decode_stream(stream)

    out = _extract_result(stream.result)
    logger.debug(f"{out.text=} {out.emotion=} {out.event=} {out.lang=}")
    return out
