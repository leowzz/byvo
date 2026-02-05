"""转写记录 ORM 模型。"""

from datetime import datetime

from sqlalchemy import DateTime, Integer, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base  # noqa: I001


class TranscriptionRecord(Base):
    """转写记录，持久化到 SQLite。"""

    __tablename__ = "transcription_records"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    engine: Mapped[str] = mapped_column(String(32), nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False)
    emotion: Mapped[str | None] = mapped_column(String(64), nullable=True)
    event: Mapped[str | None] = mapped_column(String(128), nullable=True)
    lang: Mapped[str | None] = mapped_column(String(16), nullable=True)
    audio_size: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=False),
        server_default=func.now(),
        nullable=False,
    )
