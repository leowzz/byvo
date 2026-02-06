"""转写 API：POST /api/v1/transcribe，豆包 ASR。"""

import asyncio
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from loguru import logger
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.transcription import TranscriptionRecord
from app.schemas.transcription import TranscribeResponse
from app.services import volcengine

router = APIRouter()


@router.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(
    audio: UploadFile = File(...),
    db: Session = Depends(get_db),
) -> TranscribeResponse:
    """上传 WAV 音频，豆包转写，结果持久化后返回。"""
    if not audio.filename or not audio.filename.lower().endswith((".wav", ".wave")):
        raise HTTPException(status_code=400, detail="仅支持 WAV 格式")

    try:
        content = await audio.read()
    except Exception as e:
        logger.error(f"{e=}")
        raise HTTPException(status_code=400, detail="读取音频失败") from e

    audio_size = len(content)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp.write(content)
        tmp_path = Path(tmp.name)

    try:
        loop = asyncio.get_running_loop()
        start = loop.time()
        result = await volcengine.transcribe_volcengine(tmp_path)
        elapsed = loop.time() - start
        logger.info(f"volcengine {elapsed=:.2f}s {len(result.text)=}")

        record = TranscriptionRecord(
            engine="volcengine",
            text=result.text,
            emotion=result.emotion,
            event=result.event,
            lang=result.lang,
            audio_size=audio_size,
        )
        db.add(record)
        db.commit()
        db.refresh(record)

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
        raise HTTPException(status_code=400, detail=str(e)) from e
    finally:
        tmp_path.unlink(missing_ok=True)
