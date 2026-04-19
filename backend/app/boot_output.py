from io import StringIO
from urllib.parse import urlencode

import qrcode
from loguru import logger

from app.config import settings


def build_setup_payload(*, api_base_url: str, api_key: str) -> str | None:
    base_url = api_base_url.strip()
    key = api_key.strip()
    if not base_url or not key:
        return None
    return f"byvo://setup?{urlencode({'base_url': base_url, 'api_key': key})}"


def _render_ascii_qr(payload: str) -> str:
    qr = qrcode.QRCode(border=1)
    qr.add_data(payload)
    qr.make(fit=True)
    buffer = StringIO()
    qr.print_ascii(out=buffer, tty=False, invert=True)
    return buffer.getvalue()


def print_setup_qr_to_stdout() -> None:
    if not settings.api_base_url.strip():
        logger.info("api_base_url is empty, skip setup QR output")
        return

    keys = settings.auth.normalized_api_keys
    if not keys:
        logger.info("auth.api_keys is empty, skip setup QR output")
        return

    api_key = keys[0]
    payload = build_setup_payload(api_base_url=settings.api_base_url, api_key=api_key)
    if payload is None:
        logger.info("setup payload is incomplete, skip setup QR output")
        return

    logger.info("setup QR uses the first configured API key")
    print("")
    print("=== byvo setup QR ===")
    print(f"API Base URL: {settings.api_base_url}")
    print(f"API Key: {api_key}")
    print(_render_ascii_qr(payload))
    print(payload)
    print("=====================")
    print("")
