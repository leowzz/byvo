# Backend Dockerization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-oriented Docker workflow for the FastAPI backend with persistent SQLite storage, mounted config, health checks, and updated documentation.

**Architecture:** Build the backend from `backend/` with a single production-oriented multi-stage Dockerfile and run it through a root-level `docker-compose.yml`. Keep the existing YAML-plus-environment config model, make SQLite persistence explicit in Docker with a mounted `/data` path, and verify the setup with backend tests plus Docker build/run checks.

**Tech Stack:** FastAPI, uvicorn, uv/uv.lock, Docker, Docker Compose, pytest, SQLite

---

## File Map

- Create: `backend/Dockerfile`
- Create: `backend/.dockerignore`
- Create: `docker-compose.yml`
- Modify: `backend/tests/conftest.py`
- Modify: `backend/tests/test_boot_output.py`
- Modify: `README.md`
- Potentially modify: `backend/app/config.py`

`backend/Dockerfile` is responsible for deterministic multi-stage image builds, runtime hardening, and the container startup command.

`backend/.dockerignore` is responsible for keeping the image build context clean and small.

`docker-compose.yml` is responsible for standard local/server startup, port publishing, config/data mounts, environment overrides, health checks, and restart behavior.

`backend/tests/conftest.py` and `backend/tests/test_boot_output.py` are responsible for guarding any touched config-path behavior if the Docker persistence path requires an app-level defaulting helper or config-related behavior change.

`README.md` is responsible for documenting Docker setup, config, persistence, and run commands.

## Behavior Surface To Preserve

- The backend must still start with `uv run uvicorn app.main:app --host 0.0.0.0 --port 8000`.
- `backend/config/config.yaml` must still be read by default when present.
- Environment variables must still override YAML settings.
- `/health` must still return HTTP 200 with `{"status":"ok"}` semantics.
- Existing non-Docker local workflows must continue to work.

## Baseline Verification

### Task 1: Run baseline backend tests

**Files:**
- Modify: none
- Test: `backend/tests/test_auth_http.py`
- Test: `backend/tests/test_auth_ws.py`
- Test: `backend/tests/test_boot_output.py`

- [ ] **Step 1: Run the backend test suite before edits**

```bash
cd backend && uv run pytest -v
```

- [ ] **Step 2: Record the baseline result**

Expected:

- existing tests pass
- the command is reusable after each meaningful change

- [ ] **Step 3: Commit nothing yet**

This task establishes the verification baseline only.

### Task 2: Add a characterization test if config behavior changes

**Files:**
- Modify: `backend/tests/conftest.py`
- Modify: `backend/tests/test_boot_output.py`
- Test: `backend/tests/test_boot_output.py`

- [ ] **Step 1: Write the failing test only if implementation changes observable config behavior**

```python
def test_settings_allow_explicit_database_url_override(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite:////data/byvo.db")

    from app.config import Settings

    settings = Settings()

    assert settings.database_url == "sqlite:////data/byvo.db"
```

- [ ] **Step 2: Run the targeted test to verify it fails only if the behavior is missing**

Run:

```bash
cd backend && uv run pytest tests/test_boot_output.py::test_settings_allow_explicit_database_url_override -v
```

Expected:

- fail only if the implementation path adds behavior that is not already covered
- if the test already passes with current behavior, keep or drop it based on duplication risk

- [ ] **Step 3: Write the minimal implementation only if needed**

```python
database_url: str = Field(default="sqlite:///./byvo.db")
```

or, if a helper is introduced:

```python
def default_database_url() -> str:
    return "sqlite:///./byvo.db"
```

- [ ] **Step 4: Re-run the targeted test**

Run:

```bash
cd backend && uv run pytest tests/test_boot_output.py -v
```

Expected:

- targeted tests pass

- [ ] **Step 5: Commit the config/test adjustment**

```bash
git add backend/tests/conftest.py backend/tests/test_boot_output.py backend/app/config.py
git commit -m "test: cover backend database url overrides"
```

Skip this task entirely if no app-level config change is required.

### Task 3: Add backend Docker build inputs

**Files:**
- Create: `backend/Dockerfile`
- Create: `backend/.dockerignore`

- [ ] **Step 1: Write the Dockerfile content**

```dockerfile
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY app ./app
COPY config ./config

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

RUN groupadd --system appuser \
    && useradd --system --gid appuser --create-home --home-dir /home/appuser appuser \
    && mkdir -p /data \
    && chown -R appuser:appuser /data

COPY --from=builder /app/.venv /app/.venv
COPY --from=builder /app/app /app/app
COPY --from=builder /app/config /app/config

EXPOSE 8000

USER appuser

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 2: Write the `.dockerignore` content**

```dockerignore
.git
.gitignore
.venv
__pycache__/
.pytest_cache/
*.pyc
*.pyo
*.pyd
byvo.db
*.db
.DS_Store
tests/__pycache__/
```

- [ ] **Step 3: Build the image to verify the files are valid**

Run:

```bash
docker build -t byvo-backend-test ./backend
```

Expected:

- image builds successfully

- [ ] **Step 4: Adjust the Dockerfile minimally if the build fails**

Allowed fixes:

- add a missing runtime package
- adjust copied paths
- pin the `uv` image reference if required

- [ ] **Step 5: Commit the Docker build inputs**

```bash
git add backend/Dockerfile backend/.dockerignore
git commit -m "build: add backend docker image"
```

### Task 4: Add Docker Compose runtime wiring

**Files:**
- Create: `docker-compose.yml`
- Potentially modify: `backend/app/config.py`

- [ ] **Step 1: Write the compose file**

```yaml
services:
  backend:
    build:
      context: ./backend
    ports:
      - "8000:8000"
    environment:
      DATABASE_URL: sqlite:////data/byvo.db
    volumes:
      - ./backend/config:/app/config:ro
      - ./backend/data:/data
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    restart: unless-stopped
```

- [ ] **Step 2: Validate the compose file**

Run:

```bash
docker compose config
```

Expected:

- compose file resolves without schema or interpolation errors

- [ ] **Step 3: Make the smallest config change only if compose cannot cleanly provide the database path**

Minimal acceptable implementation:

```python
database_url: str = Field(default="sqlite:///./byvo.db")
```

Preferred outcome:

- no code change
- Docker sets `DATABASE_URL` explicitly

- [ ] **Step 4: Re-run targeted backend tests if config code changed**

Run:

```bash
cd backend && uv run pytest tests/test_boot_output.py -v
```

Expected:

- config-related tests pass

- [ ] **Step 5: Commit the compose/config wiring**

```bash
git add docker-compose.yml backend/app/config.py backend/tests/test_boot_output.py backend/tests/conftest.py
git commit -m "build: add backend compose workflow"
```

### Task 5: Document the Docker workflow

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a Docker section to the README**

```md
## Docker 部署后端

1. 准备配置文件：

```bash
cp backend/config/config.yaml.example backend/config/config.yaml
```

2. 按需修改 `backend/config/config.yaml`，或使用环境变量覆盖：

```bash
AUTH__API_KEYS='["replace-with-a-long-random-key"]'
VOLCENGINE__APP_KEY=...
VOLCENGINE__ACCESS_KEY=...
VOLCENGINE__RESOURCE_ID=...
```

3. 启动服务：

```bash
docker compose up -d --build
```

4. 验证健康检查：

```bash
curl http://127.0.0.1:8000/health
```

SQLite 数据默认持久化在 `backend/data/`，容器配置文件来自 `backend/config/`。该方案适用于本地开发、Linux x86_64 和 Linux ARM64 环境。
```

- [ ] **Step 2: Ensure the README still documents the non-Docker backend workflow**

Expected:

- existing `uv`-based local workflow remains documented

- [ ] **Step 3: Re-read the README section for command accuracy**

Check:

- compose command paths are correct
- mounted paths match `docker-compose.yml`
- environment variable names match `backend/app/config.py`

- [ ] **Step 4: Commit the docs update**

```bash
git add README.md
git commit -m "docs: add backend docker workflow"
```

### Task 6: End-to-end Docker verification

**Files:**
- Modify: none
- Test: `docker-compose.yml`
- Test: `backend/Dockerfile`

- [ ] **Step 1: Run the backend test suite again**

Run:

```bash
cd backend && uv run pytest -v
```

Expected:

- all backend tests pass

- [ ] **Step 2: Re-validate compose configuration**

Run:

```bash
docker compose config
```

Expected:

- compose renders successfully

- [ ] **Step 3: Build and start the backend**

Run:

```bash
docker compose up -d --build
```

Expected:

- image builds
- container starts

- [ ] **Step 4: Verify health endpoint from the host**

Run:

```bash
curl http://127.0.0.1:8000/health
```

Expected:

```json
{"status":"ok"}
```

- [ ] **Step 5: Verify persistence path creation**

Run:

```bash
ls -la backend/data
```

Expected:

- mounted data directory exists
- SQLite file appears after startup or first DB use

- [ ] **Step 6: Stop the stack after verification if desired**

Run:

```bash
docker compose down
```

- [ ] **Step 7: Commit the final verified state**

```bash
git add backend/Dockerfile backend/.dockerignore docker-compose.yml README.md backend/app/config.py backend/tests/conftest.py backend/tests/test_boot_output.py
git commit -m "feat: dockerize backend deployment"
```

## Self-Review

Spec coverage:

- Docker image: Task 3
- `.dockerignore`: Task 3
- compose workflow: Task 4
- explicit SQLite persistence path in Docker: Task 4
- documentation: Task 5
- verification with tests and Docker runtime: Task 6

Placeholder scan:

- No `TODO`, `TBD`, or “implement later” placeholders remain.
- The optional config-test task is explicitly marked skippable only if the implementation does not change behavior.

Type consistency:

- `DATABASE_URL` matches the `database_url` field in `backend/app/config.py` under `BaseSettings`.
- Docker health checks target the existing `/health` endpoint.
