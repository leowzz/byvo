"""转写 API：POST /api/v1/transcribe。"""

import asyncio
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from loguru import logger
from sqlalchemy.orm import Session

from app.database import get_db
from app.models.transcription import TranscriptionRecord
from app.schemas.transcription import TranscribeResponse
from app.services import sensevoice, volcengine

router = APIRouter()


@router.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(
    audio: UploadFile = File(...),
    engine: str = Form("volcengine"),
    db: Session = Depends(get_db),
) -> TranscribeResponse:
    """
    上传 WAV 音频，使用指定引擎转写，结果持久化后返回。
    engine: sensevoice | volcengine
    """
    if engine not in ("sensevoice", "volcengine"):
        raise HTTPException(status_code=400, detail=f"不支持的引擎: {engine}")

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
    loop = asyncio.get_running_loop()
    start = loop.time()

    try:
        if engine == "volcengine":
            text, emotion, event, lang = await volcengine.transcribe_volcengine(tmp_path)
        else:
            text, emotion, event, lang = await asyncio.to_thread(
                sensevoice.transcribe_sensevoice, tmp_path
            )

        elapsed = loop.time() - start
        logger.info(f"{engine=} {elapsed=:.2f}s {len(text)=}")

        record = TranscriptionRecord(
            engine=engine,
            text=text,
            emotion=emotion,
            event=event,
            lang=lang,
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
