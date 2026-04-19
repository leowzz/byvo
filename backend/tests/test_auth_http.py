from io import BytesIO


def _wav_file() -> tuple[str, BytesIO, str]:
    return ("sample.wav", BytesIO(b"RIFFdemoWAVEfmt "), "audio/wav")


def test_transcribe_rejects_missing_api_key(client):
    response = client.post("/api/v1/transcribe", files={"audio": _wav_file()})

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid api key"}


def test_transcribe_rejects_invalid_api_key(client):
    response = client.post(
        "/api/v1/transcribe",
        files={"audio": _wav_file()},
        headers={"X-API-Key": "wrong-key"},
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid api key"}


def test_transcribe_accepts_valid_api_key(client):
    response = client.post(
        "/api/v1/transcribe",
        files={"audio": _wav_file()},
        headers={"X-API-Key": "test-key"},
    )

    assert response.status_code == 200
    assert response.json()["text"] == "ok"


def test_auth_check_rejects_missing_api_key(client):
    response = client.get("/api/v1/auth-check")

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid api key"}


def test_auth_check_rejects_invalid_api_key(client):
    response = client.get(
        "/api/v1/auth-check",
        headers={"X-API-Key": "wrong-key"},
    )

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid api key"}


def test_auth_check_accepts_valid_api_key(client):
    response = client.get(
        "/api/v1/auth-check",
        headers={"X-API-Key": "test-key"},
    )

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
