from app import boot_output


def test_build_setup_payload_returns_uri_for_base_url_and_key():
    payload = boot_output.build_setup_payload(
        api_base_url="http://192.168.1.20:8000",
        api_key="demo-key",
    )

    assert payload == (
        "byvo://setup?"
        "base_url=http%3A%2F%2F192.168.1.20%3A8000&"
        "api_key=demo-key"
    )


def test_build_setup_payload_returns_none_when_base_url_missing():
    payload = boot_output.build_setup_payload(
        api_base_url="",
        api_key="demo-key",
    )

    assert payload is None


def test_build_setup_payload_returns_none_when_api_key_missing():
    payload = boot_output.build_setup_payload(
        api_base_url="http://192.168.1.20:8000",
        api_key="",
    )

    assert payload is None


def test_print_setup_qr_to_stdout_skips_when_base_url_missing(monkeypatch):
    monkeypatch.setattr(boot_output.settings, "api_base_url", "")
    monkeypatch.setattr(boot_output.settings.auth, "api_keys", ["demo-key"])

    messages: list[str] = []
    monkeypatch.setattr(boot_output.logger, "info", messages.append)

    boot_output.print_setup_qr_to_stdout()

    assert messages == ["api_base_url is empty, skip setup QR output"]
