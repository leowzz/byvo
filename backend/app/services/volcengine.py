"""豆包大模型语音识别服务，WebSocket 协议。"""

import asyncio
import json
import struct
import time
from collections.abc import AsyncIterator
from pathlib import Path

import numpy as np
import soundfile as sf
import websockets
from loguru import logger

from app.config import settings
from app.schemas.transcription import TranscribeResult

# 豆包 SAUC 协议常量
WSS_NOSTREAM = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
WSS_STREAM = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
HEADER_FULL_CLIENT = 0x11101000
HEADER_AUDIO_ONLY = 0x11200000
HEADER_AUDIO_LAST = 0x11220000
CHUNK_BYTES = 3200 * 2  # 200ms at 16k/16bit
TARGET_SR = 16000


def _uuid() -> str:
    t = time.time_ns()
    return f"{t // 1_000_000}-{((t % 1_000_000) // 10) % 100000:05d}"


def _ws_headers(volc) -> dict[str, str]:
    return {
        "X-Api-App-Key": volc.app_key,
        "X-Api-Access-Key": volc.access_key,
        "X-Api-Resource-Id": volc.resource_id,
        "X-Api-Connect-Id": _uuid(),
    }


def _request_body(effect: bool) -> dict:
    return {
        "audio": {"format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
        "request": {
            "model_name": "bigmodel",
            "enable_itn": True,
            "enable_punc": True,
            "enable_ddc": effect,
        },
    }


def _build_packet(header: int, payload: bytes) -> bytes:
    buf = bytearray(8 + len(payload))
    struct.pack_into(">I", buf, 0, header)
    struct.pack_into(">I", buf, 4, len(payload))
    buf[8:] = payload
    return bytes(buf)


def _parse_asr_message(data: bytes) -> tuple[str | None, bool]:
    """
    解析豆包响应包，返回 (文本或 None, 是否最后一包)。
    message_type 0x0F 为错误，0x09 为结果；flags 0x03 表示结束。
    """
    if len(data) < 4:
        return None, False
    msg_type = (data[1] >> 4) & 0x0F
    flags = data[1] & 0x0F
    if msg_type == 0x0F:
        code = struct.unpack_from(">I", data, 4)[0] if len(data) >= 8 else 0
        raise RuntimeError(f"豆包 API 错误: code={code}")
    if msg_type != 0x09 or len(data) < 12:
        return None, flags == 0x03
    size = struct.unpack_from(">I", data, 8)[0]
    if len(data) < 12 + size:
        return None, flags == 0x03
    try:
        obj = json.loads(data[12 : 12 + size].decode("utf-8"))
        raw = obj.get("result")
        if isinstance(raw, dict):
            t = raw.get("text") or ""
        elif isinstance(raw, str):
            t = raw
        else:
            t = ""
        return t if t else None, flags == 0x03
    except (json.JSONDecodeError, KeyError):
        return None, flags == 0x03


def _read_wav_16k_mono(path: str | Path) -> bytes:
    """读取 WAV，转为 16k mono PCM bytes。"""
    audio, sr = sf.read(path, dtype="float32", always_2d=True)
    if audio.ndim == 2:
        audio = audio[:, 0]
    if sr != TARGET_SR:
        in_len = len(audio)
        out_len = int(in_len * TARGET_SR / sr)
        indices = np.linspace(0, in_len - 1, out_len)
        audio = np.interp(indices, np.arange(in_len), audio)
    pcm = (audio * 32767).astype(np.int16)
    return pcm.tobytes()


async def transcribe_volcengine(
    audio_path: str | Path,
    *,
    effect: bool = False,
) -> TranscribeResult:
    """豆包非流式转写：上传整段音频，返回全文。"""
    volc = settings.volcengine
    if not volc.valid:
        raise ValueError("豆包 API 未配置")

    pcm = _read_wav_16k_mono(audio_path)
    logger.debug(f"{len(pcm)=}")

    async with websockets.connect(WSS_NOSTREAM, additional_headers=_ws_headers(volc), proxy=None) as ws:
        body = _request_body(effect)
        await ws.send(_build_packet(HEADER_FULL_CLIENT, json.dumps(body, ensure_ascii=False).encode()))

        offset = 0
        while offset < len(pcm):
            take = min(CHUNK_BYTES, len(pcm) - offset)
            is_last = offset + take >= len(pcm)
            header = HEADER_AUDIO_LAST if is_last else HEADER_AUDIO_ONLY
            await ws.send(_build_packet(header, pcm[offset : offset + take]))
            offset += take
            if not is_last:
                await asyncio.sleep(0.05)

        texts: list[str] = []

        async def _receive_until_done() -> None:
            async for msg in ws:
                if not isinstance(msg, (bytes, bytearray)):
                    continue
                t, done = _parse_asr_message(bytes(msg))
                if t:
                    texts.append(t)
                if done:
                    return

        try:
            await asyncio.wait_for(_receive_until_done(), timeout=30)
        except asyncio.TimeoutError:
            logger.warning("ASR receive timeout 30s")

    result = "".join(texts).strip()
    logger.info(f"ASR(豆包) {len(result)=}")
    return TranscribeResult(text=result)


async def transcribe_volcengine_stream(
    audio_stream: AsyncIterator[bytes],
    *,
    effect: bool = False,
) -> AsyncIterator[str]:
    """流式转写：PCM 流 → 豆包 → yield 增量识别全文。"""
    volc = settings.volcengine
    if not volc.valid:
        raise ValueError("豆包 API 未配置")

    async with websockets.connect(WSS_STREAM, additional_headers=_ws_headers(volc), proxy=None) as ws:
        await ws.send(_build_packet(HEADER_FULL_CLIENT, json.dumps(_request_body(effect), ensure_ascii=False).encode()))

        send_done = asyncio.Event()

        async def send_audio() -> None:
            buffer = bytearray()
            try:
                async for chunk in audio_stream:
                    buffer.extend(chunk)
                    while len(buffer) >= CHUNK_BYTES:
                        pkt = _build_packet(HEADER_AUDIO_ONLY, bytes(buffer[:CHUNK_BYTES]))
                        del buffer[:CHUNK_BYTES]
                        await ws.send(pkt)
                        await asyncio.sleep(0.05)
                if buffer:
                    await ws.send(_build_packet(HEADER_AUDIO_LAST, bytes(buffer)))
                else:
                    await ws.send(_build_packet(HEADER_AUDIO_LAST, b""))
            except Exception as e:
                logger.warning(f"stream send error: {e=}")
            finally:
                send_done.set()

        send_task = asyncio.create_task(send_audio())
        try:
            last = ""
            async for msg in ws:
                if not isinstance(msg, (bytes, bytearray)):
                    continue
                t, done = _parse_asr_message(bytes(msg))
                if t and t != last:
                    logger.debug(f"ASR 流式: {t=}")
                    yield t
                    last = t
                if done:
                    break
        finally:
            await send_done.wait()
            send_task.cancel()
            try:
                await send_task
            except asyncio.CancelledError:
                pass
