"""火山方舟 Ark 流式纠错：对 ASR 文本实时润色与纠错（Typeless 风格）。"""

import asyncio
from collections.abc import AsyncIterator

from loguru import logger

from app.config import settings

SYSTEM_PROMPT = (
    "你是语音助理，请对以下流式 ASR 文本进行实时润色和纠错。"
    "保持原意，修正错别字和口语冗余。仅输出修正后的文本。"
)


def _correct_stream_sync(asr_text: str, history: str, api_key: str, model_id: str) -> list[str]:
    """
    同步调用 Ark chat completions（stream=True），收集纠错结果并返回全文列表。
    在 asyncio.to_thread 中调用，避免阻塞事件循环。
    """
    from volcenginesdkarkruntime import Ark

    client = Ark(api_key=api_key)
    logger.info(f"Ark(豆包) 纠错 输入: {asr_text=}")
    user_content = f"历史文本: {history}\n\n当前待纠错: {asr_text}" if history else f"当前待纠错: {asr_text}"
    chunks: list[str] = []
    try:
        stream = client.chat.completions.create(
            model=model_id,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
            ],
            stream=True,
            temperature=0.3,
            thinking={"type": "disabled"},  # 关闭深度思考，降低延迟
        )
        for chunk in stream:
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta
            if hasattr(delta, "content") and delta.content:
                chunks.append(delta.content)
    except Exception as e:
        logger.warning(f"Ark correction error: {e=}")
    out = "".join(chunks)
    logger.info(f"Ark(豆包) 纠错 输出: {out=}")
    return chunks


async def correct_stream(
    asr_text: str,
    history: str = "",
) -> AsyncIterator[str]:
    """
    对 ASR 文本调用火山方舟 Ark 进行流式纠错，yield 纠错后的增量片段（可拼接为全文）。

    :param asr_text: 当前待纠错的 ASR 全文
    :param history: 最近几句历史（上下文），可为空
    :yield: 纠错后的文本片段
    """
    volc = settings.volcengine
    if not volc.ark_valid:
        if asr_text:
            yield asr_text
        return

    if not asr_text.strip():
        yield ""
        return

    loop = asyncio.get_running_loop()
    chunks = await loop.run_in_executor(
        None,
        lambda: _correct_stream_sync(asr_text, history, volc.ark_api_key, volc.ark_model_id),
    )
    for c in chunks:
        yield c


async def correct_full(asr_text: str, history: str = "") -> str:
    """对 ASR 文本做一次纠错，返回完整纠错结果（非流式）。"""
    out: list[str] = []
    async for chunk in correct_stream(asr_text, history):
        out.append(chunk)
    return "".join(out).strip() if out else asr_text
