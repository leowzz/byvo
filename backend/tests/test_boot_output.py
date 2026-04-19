import pytest


def _build_setup_payload(*, api_base_url: str, api_key: str):
    try:
        from app import boot_output
    except (ImportError, ModuleNotFoundError):
        pytest.fail("missing implementation: app.boot_output module is not created yet")

    if not hasattr(boot_output, "build_setup_payload"):
        pytest.fail("missing implementation: build_setup_payload is not implemented yet")

    return boot_output.build_setup_payload(api_base_url=api_base_url, api_key=api_key)


def test_build_setup_payload_returns_uri_for_base_url_and_key():
    payload = _build_setup_payload(
        api_base_url="http://192.168.1.20:8000",
        api_key="demo-key",
    )

    assert payload == (
        "byvo://setup?"
        "base_url=http%3A%2F%2F192.168.1.20%3A8000&"
        "api_key=demo-key"
    )


def test_build_setup_payload_returns_none_when_base_url_missing():
    payload = _build_setup_payload(
        api_base_url="",
        api_key="demo-key",
    )

    assert payload is None


def test_build_setup_payload_returns_none_when_api_key_missing():
    payload = _build_setup_payload(
        api_base_url="http://192.168.1.20:8000",
        api_key="",
    )

    assert payload is None
