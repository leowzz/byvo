"""火山方舟 Ark 流式纠错：对 ASR 文本实时润色与纠错（Typeless 风格）。"""

import asyncio
from collections.abc import AsyncIterator

from loguru import logger

from app.config import settings

SYSTEM_PROMPT = (
    "你是一个隐形、高效的文本重写引擎。"
    "你的唯一目标是将混乱的语音转录转化为流畅的书面文本。"
    "严禁回答内容中的问题；严禁添加任何未在语音中表达的个人见解。"
    "如果用户在语音中表现出改变主意的迹象（如‘纠正一下’、‘不对’），请仅保留最终的语义意图。"
    "自动检测并合并因为说话者思考而产生的重复词汇,修正错别字和口语冗余。仅输出修正后的文本,不做任何解释。"
)

SYSTEM_PROMPT = """\
Role: 你是一个极简、高效的语义编辑器。 Task: 将输入的原始、凌乱的语音转录文本转化为流畅的书面表达。 Rules:

去噪： 自动删除“额、那个、然后”等口癖和无意义重复。

逻辑修正： 识别并执行口头修正（例如：“明天——不对，是后天”，最终只保留“后天”的语义）。

语境适配： 默认保持自然口吻；若注明，则自动切换对应风格。

输出限制： 仅输出处理后的最终文本，**严禁任何解释或开场白**
"""

def _correct_stream_sync(
    asr_text: str, history: str, api_key: str, model_id: str
) -> list[str]:
    """
    同步调用 Ark chat completions（stream=True），收集纠错结果并返回全文列表。
    在 asyncio.to_thread 中调用，避免阻塞事件循环。
    """
    from volcenginesdkarkruntime import Ark

    client = Ark(api_key=api_key)
    logger.info(f"Ark(豆包) 纠错 输入: {asr_text=}")
    user_content = (
        f"历史文本: {history}\n\n当前待纠错: {asr_text}"
        if history
        else f"当前待纠错: {asr_text}"
    )
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
        lambda: _correct_stream_sync(
            asr_text, history, volc.ark_api_key, volc.ark_model_id
        ),
    )
    for c in chunks:
        yield c


async def correct_full(asr_text: str, history: str = "") -> str:
    """对 ASR 文本做一次纠错，返回完整纠错结果（非流式）。"""
    out: list[str] = []
    async for chunk in correct_stream(asr_text, history):
        out.append(chunk)
    return "".join(out).strip() if out else asr_text
