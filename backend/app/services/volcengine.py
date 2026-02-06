"""豆包大模型语音识别服务，WebSocket 协议与 Dart 端一致。"""

import asyncio
import json
import struct
import time
from collections.abc import AsyncIterator
from pathlib import Path

import soundfile as sf
import websockets
from loguru import logger

from app.config import settings
from app.schemas.transcription import TranscribeResult


WSS_URL_NOSTREAM = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"
WSS_URL_STREAM = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

HEADER_FULL_CLIENT = 0x11101000
HEADER_AUDIO_ONLY = 0x11200000
HEADER_AUDIO_LAST = 0x11220000

CHUNK_SAMPLES = 3200  # 200ms at 16k
CHUNK_BYTES = CHUNK_SAMPLES * 2

TARGET_SAMPLE_RATE = 16000


def _uuid() -> str:
    t = time.time_ns()
    return f"{t // 1_000_000}-{((t % 1_000_000) // 10) % 100000:05d}"


def _write_header(buf: bytearray, header: int) -> None:
    struct.pack_into(">I", buf, 0, header)


def _write_payload_size(buf: bytearray, offset: int, size: int) -> None:
    struct.pack_into(">I", buf, offset, size)


def _read_wav_to_16k_mono(path: str | Path) -> tuple[bytes, int]:
    """读取 WAV 转为 16k mono PCM bytes。"""
    audio, sr = sf.read(path, dtype="float32", always_2d=True)
    if audio.ndim == 2:
        audio = audio[:, 0]
    if sr != TARGET_SAMPLE_RATE:
        # 简单线性重采样
        import numpy as np

        in_len = len(audio)
        out_len = int(in_len * TARGET_SAMPLE_RATE / sr)
        indices = np.linspace(0, in_len - 1, out_len)
        audio = np.interp(indices, np.arange(in_len), audio)
        sr = TARGET_SAMPLE_RATE
    # float32 [-1,1] -> int16
    import numpy as np

    pcm = (audio * 32767).astype(np.int16)
    return pcm.tobytes(), sr


async def transcribe_volcengine(audio_path: str | Path) -> TranscribeResult:
    """调用豆包 API 转写音频；豆包仅返回 text，其余为 None。"""
    volc = settings.volcengine
    if not volc.valid:
        raise ValueError("豆包 API 未配置，请设置 config/config.yaml 或环境变量 VOLCENGINE__APP_KEY 等")

    pcm_bytes, _ = _read_wav_to_16k_mono(audio_path)
    connect_id = _uuid()
    headers = {
        "X-Api-App-Key": volc.app_key,
        "X-Api-Access-Key": volc.access_key,
        "X-Api-Resource-Id": volc.resource_id,
        "X-Api-Connect-Id": connect_id,
    }
    logger.debug(f"{connect_id=} {len(pcm_bytes)=}")

    async with websockets.connect(
        WSS_URL_NOSTREAM,
        additional_headers=headers,
        proxy=None,  # 禁用代理，避免 proxy 路径下 extra_headers 传给 create_connection 的兼容性问题
    ) as ws:
        # 1. 发送 full client request
        body = {
            "audio": {
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
            },
            "request": {
                "model_name": "bigmodel",
                "enable_itn": True,
                "enable_punc": True,
            },
        }
        json_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
        total = 4 + 4 + len(json_bytes)
        packet = bytearray(total)
        _write_header(packet, HEADER_FULL_CLIENT)
        _write_payload_size(packet, 4, len(json_bytes))
        packet[8 : 8 + len(json_bytes)] = json_bytes
        await ws.send(bytes(packet))

        # 2. 发送 audio chunks
        offset = 0
        while offset < len(pcm_bytes):
            remaining = len(pcm_bytes) - offset
            is_last = remaining <= CHUNK_BYTES
            take = min(remaining, CHUNK_BYTES)
            header = HEADER_AUDIO_LAST if is_last else HEADER_AUDIO_ONLY
            total = 4 + 4 + take
            packet = bytearray(total)
            _write_header(packet, header)
            _write_payload_size(packet, 4, take)
            packet[8 : 8 + take] = pcm_bytes[offset : offset + take]
            await ws.send(bytes(packet))
            offset += take
            if not is_last:
                await asyncio.sleep(0.05)

        # 3. 接收结果
        text = await _receive_final_result(ws)

    return TranscribeResult(text=text)


async def transcribe_volcengine_stream(
    audio_stream: AsyncIterator[bytes],
) -> AsyncIterator[str]:
    """
    流式转写：接收 PCM 流，边收边发豆包，yield 增量识别结果。

    :param audio_stream: PCM 16k/16bit/mono bytes 的异步迭代器
    :yield: 增量识别文本
    """
    volc = settings.volcengine
    if not volc.valid:
        raise ValueError("豆包 API 未配置，请设置 config/config.yaml 或环境变量 VOLCENGINE__APP_KEY 等")

    connect_id = _uuid()
    headers = {
        "X-Api-App-Key": volc.app_key,
        "X-Api-Access-Key": volc.access_key,
        "X-Api-Resource-Id": volc.resource_id,
        "X-Api-Connect-Id": connect_id,
    }
    logger.debug(f"stream {connect_id=}")

    async with websockets.connect(
        WSS_URL_STREAM,
        additional_headers=headers,
        proxy=None,
    ) as ws:
        # 1. 发送 full client request
        body = {
            "audio": {
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
            },
            "request": {
                "model_name": "bigmodel",
                "enable_itn": True,
                "enable_punc": True,
            },
        }
        json_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")
        total = 4 + 4 + len(json_bytes)
        packet = bytearray(total)
        _write_header(packet, HEADER_FULL_CLIENT)
        _write_payload_size(packet, 4, len(json_bytes))
        packet[8 : 8 + len(json_bytes)] = json_bytes
        await ws.send(bytes(packet))

        # 2. 消费者任务：收集 PCM，按 200ms 分包发送
        send_done = asyncio.Event()

        async def _send_audio() -> None:
            buffer = bytearray()
            try:
                async for chunk in audio_stream:
                    buffer.extend(chunk)
                    while len(buffer) >= CHUNK_BYTES:
                        take = CHUNK_BYTES
                        header = HEADER_AUDIO_ONLY
                        total = 4 + 4 + take
                        pkt = bytearray(total)
                        _write_header(pkt, header)
                        _write_payload_size(pkt, 4, take)
                        pkt[8 : 8 + take] = buffer[:take]
                        del buffer[:take]
                        await ws.send(bytes(pkt))
                        await asyncio.sleep(0.05)
                if buffer:
                    header = HEADER_AUDIO_LAST
                    total = 4 + 4 + len(buffer)
                    pkt = bytearray(total)
                    _write_header(pkt, header)
                    _write_payload_size(pkt, 4, len(buffer))
                    pkt[8 : 8 + len(buffer)] = buffer
                    await ws.send(bytes(pkt))
                else:
                    pkt = bytearray(4 + 4)
                    _write_header(pkt, HEADER_AUDIO_LAST)
                    _write_payload_size(pkt, 4, 0)
                    await ws.send(bytes(pkt))
            except Exception as e:
                logger.warning(f"stream send error: {e=}")
            finally:
                send_done.set()

        # 3. 生产者任务：接收豆包响应，yield 当前全文（供前端直接替换显示，避免追加导致重复）
        async def _receive_and_yield() -> AsyncIterator[str]:
            last_text = ""
            async for message in ws:
                if not isinstance(message, (bytes, bytearray)):
                    continue
                data = bytes(message)
                if len(data) < 4:
                    continue
                message_type = (data[1] >> 4) & 0x0F
                flags = data[1] & 0x0F
                if message_type == 0x0F:
                    code = struct.unpack_from(">I", data, 4)[0] if len(data) >= 8 else 0
                    raise RuntimeError(f"豆包 API 错误: code={code}")
                if message_type != 0x09:
                    continue
                if len(data) < 12:
                    continue
                payload_size = struct.unpack_from(">I", data, 8)[0]
                if len(data) < 12 + payload_size:
                    continue
                json_str = data[12 : 12 + payload_size].decode("utf-8")
                try:
                    obj = json.loads(json_str)
                    raw = obj.get("result")
                    if isinstance(raw, dict):
                        t = raw.get("text") or ""
                    elif isinstance(raw, str):
                        t = raw
                    else:
                        t = ""
                    if t != last_text:
                        yield t
                        last_text = t
                except (json.JSONDecodeError, KeyError):
                    pass
                if flags == 0x03:
                    break

        send_task = asyncio.create_task(_send_audio())
        try:
            async for incremental in _receive_and_yield():
                yield incremental
        finally:
            await send_done.wait()
            send_task.cancel()
            try:
                await send_task
            except asyncio.CancelledError:
                pass


async def _receive_final_result(ws: websockets.WebSocketClientProtocol) -> str:
    """解析 full server response，遇最后一包或 error 则结束。"""
    result = []
    timeout_sec = 30

    async def _collect() -> None:
        async for message in ws:
            if not isinstance(message, (bytes, bytearray)):
                continue
            data = bytes(message)
            if len(data) < 4:
                continue
            message_type = (data[1] >> 4) & 0x0F
            flags = data[1] & 0x0F
            if message_type == 0x0F:
                code = struct.unpack_from(">I", data, 4)[0] if len(data) >= 8 else 0
                raise RuntimeError(f"豆包 API 错误: code={code}")
            if message_type != 0x09:
                continue
            if len(data) < 12:
                continue
            payload_size = struct.unpack_from(">I", data, 8)[0]
            if len(data) < 12 + payload_size:
                continue
            json_str = data[12 : 12 + payload_size].decode("utf-8")
            try:
                obj = json.loads(json_str)
                raw = obj.get("result")
                if isinstance(raw, dict):
                    t = raw.get("text")
                elif isinstance(raw, str):
                    t = raw
                else:
                    t = None
                if t:
                    result.append(t)
            except (json.JSONDecodeError, KeyError):
                pass
            if flags == 0x03:
                break

    try:
        await asyncio.wait_for(_collect(), timeout=timeout_sec)
    except asyncio.TimeoutError:
        logger.warning(f"{timeout_sec=}")
    return "".join(result).strip()
