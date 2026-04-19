"""转写 API：POST /api/v1/transcribe，豆包 ASR，可选 Ark 纠错。"""

import asyncio
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from loguru import logger
from sqlalchemy.orm import Session

from app.auth import require_api_key
from app.config import settings
from app.database import get_db
from app.models.transcription import TranscriptionRecord
from app.schemas.transcription import TranscribeResponse
from app.services import ark_correction, volcengine

router = APIRouter()


def _audio_header_hex(content: bytes, limit: int = 16) -> str:
    return content[:limit].hex(" ")


def _looks_like_wav(content: bytes) -> bool:
    return len(content) >= 12 and content[:4] == b"RIFF" and content[8:12] == b"WAVE"


@router.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(
    _: None = Depends(require_api_key),
    audio: UploadFile = File(...),
    effect: bool = Query(False, description="是否开启效果转写/去口语化（语义顺滑）"),
    use_llm: bool = Query(False, description="是否启用 LLM 纠错，由后端配置决定"),
    db: Session = Depends(get_db),
) -> TranscribeResponse:
    """上传 WAV 音频，豆包转写；use_llm 且 Ark 配置有效时做纠错，结果持久化后返回。"""
    if not audio.filename or not audio.filename.lower().endswith((".wav", ".wave")):
        raise HTTPException(status_code=400, detail="仅支持 WAV 格式")

    try:
        content = await audio.read()
    except Exception as e:
        logger.error(f"{e=}")
        raise HTTPException(status_code=400, detail="读取音频失败") from e

    audio_size = len(content)
    logger.info(
        "incoming wav upload size={} header={}",
        audio_size,
        _audio_header_hex(content),
    )
    if not _looks_like_wav(content):
        logger.warning(
            "invalid wav header size={} header={}",
            audio_size,
            _audio_header_hex(content),
        )
        raise HTTPException(status_code=400, detail="音频文件不是合法 WAV")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp.write(content)
        tmp_path = Path(tmp.name)

    try:
        loop = asyncio.get_running_loop()
        start = loop.time()
        result = await volcengine.transcribe_volcengine(tmp_path, effect=effect)
        elapsed = loop.time() - start
        logger.info(f"volcengine {elapsed=:.2f}s {len(result.text)=}")

        final_text = result.text
        if use_llm and settings.volcengine.ark_valid:
            final_text = await ark_correction.correct_full(result.text, history="")
            logger.info(f"Ark 纠错后 len(final_text)={len(final_text)}")

        record = TranscriptionRecord(
            engine="volcengine",
            text=final_text,
            emotion=result.emotion,
            event=result.event,
            lang=result.lang,
            audio_size=audio_size,
        )
        db.add(record)
        db.commit()
        db.refresh(record)
        logger.debug(f"{record.id=} {record.text=}")

        return TranscribeResponse(
            id=record.id,
            text=record.text,
            emotion=record.emotion,
            event=record.event,
            lang=record.lang,
            engine=record.engine,
        )
    except (ValueError, FileNotFoundError, RuntimeError) as e:
        logger.warning(f"{e=}")
        detail = str(e)
        if e.__class__.__name__ == "LibsndfileError":
            detail = "音频文件不是合法 WAV"
        raise HTTPException(status_code=400, detail=detail) from e
    finally:
        tmp_path.unlink(missing_ok=True)
