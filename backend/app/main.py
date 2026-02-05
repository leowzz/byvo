"""FastAPI 应用入口。"""

import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from loguru import logger

from app.api.v1 import router as api_v1_router
from app.database import init_db


def _setup_loguru() -> None:
    """配置 Loguru 日志。"""
    logger.remove()
    logger.add(
        sys.stderr,
        format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level: <8}</level> | <cyan>{name}</cyan>:<cyan>{function}</cyan>:<cyan>{line}</cyan> - <level>{message}</level>",
        level="INFO",
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期：启动时初始化数据库。"""
    init_db()
    logger.info("byvo backend started")
    yield
    logger.info("byvo backend shutdown")


app = FastAPI(
    title="byvo",
    description="语音转写 API",
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(api_v1_router)


@app.get("/health")
def health() -> dict:
    """健康检查。"""
    return {"status": "ok"}


def main() -> None:
    """启动 uvicorn。"""
    _setup_loguru()
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
    )


if __name__ == "__main__":
    main()
