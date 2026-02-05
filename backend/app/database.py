"""SQLAlchemy 引擎与会话，启动时 create_all 创建表。"""

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, declarative_base, sessionmaker

from app.config import settings

engine = create_engine(
    settings.database_url,
    connect_args={"check_same_thread": False} if "sqlite" in settings.database_url else {},
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def init_db() -> None:
    """创建所有表。"""
    from app.models import transcription  # noqa: F401 - 注册模型

    Base.metadata.create_all(bind=engine)


def get_db() -> Session:
    """依赖注入用数据库会话。"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
