"""API v1 路由。"""

from fastapi import APIRouter

from app.api.v1 import transcribe, transcribe_ws

router = APIRouter(prefix="/api/v1", tags=["v1"])
router.include_router(transcribe.router, prefix="", tags=["transcribe"])
router.include_router(transcribe_ws.router, prefix="", tags=["transcribe"])
