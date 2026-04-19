"""轻量鉴权检查接口。"""

from fastapi import APIRouter, Depends

from app.auth import require_api_key

router = APIRouter()


@router.get("/auth-check")
def auth_check(_: None = Depends(require_api_key)) -> dict[str, str]:
    """校验 API Key 是否可用。"""
    return {"status": "ok"}
