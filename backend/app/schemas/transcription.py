"""转写 API 与服务层 Pydantic schema。"""

from pydantic import BaseModel, Field


class TranscribeResult(BaseModel):
    """服务层转写结果，供 sensevoice/volcengine 统一返回。"""

    text: str = Field("", description="转写文本")
    emotion: str | None = Field(None, description="情感标签")
    event: str | None = Field(None, description="环境音/事件标签")
    lang: str | None = Field(None, description="语种")


class TranscribeResponse(BaseModel):
    """POST /api/v1/transcribe 响应。"""

    id: int = Field(..., description="持久化记录 ID")
    text: str = Field(..., description="转写文本")
    emotion: str | None = Field(None, description="情感标签")
    event: str | None = Field(None, description="环境音/事件标签")
    lang: str | None = Field(None, description="语种")
    engine: str = Field(..., description="使用的引擎")
