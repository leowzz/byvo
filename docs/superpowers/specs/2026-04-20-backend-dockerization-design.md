# Backend Dockerization Design

## Context

`backend/` is a standalone FastAPI service started with `uvicorn app.main:app --host 0.0.0.0 --port 8000`. It uses:

- `pyproject.toml` + `uv.lock` for Python dependency management
- `config/config.yaml` plus environment-variable overrides for runtime config
- SQLite for persistence, currently defaulting to `sqlite:///./byvo.db`

The goal is to make the backend runnable in Docker on:

- local development machines
- Linux x86_64 servers
- Linux ARM64 servers

The priority is a production-oriented containerization path. Development support only needs to be good enough to run the service in Docker, not to provide first-class hot reload.

## Goals

- Build and run the backend as a single container
- Provide a simple `docker compose` entrypoint for local use and server deployment
- Keep SQLite persistence across container restarts
- Keep the existing config model: YAML file plus environment variable overrides
- Improve production safety with non-root runtime and health checks
- Keep the solution compatible with both x86_64 and ARM64 by using multi-arch-friendly base images

## Non-Goals

- Replacing SQLite with Postgres or any external database
- Adding Redis, reverse proxy, or orchestration-specific files
- Creating a separate hot-reload-first development container workflow
- Changing backend business behavior unrelated to container startup, config, or persistence

## Recommended Approach

Use a single production-oriented Docker build and a root-level `docker-compose.yml`.

This keeps the deployment model easy to understand:

- one `backend/Dockerfile` for image builds
- one root-level `docker-compose.yml` for running the service
- one stable persisted data path for SQLite
- one mounted config directory for `config.yaml`

This is the lowest-maintenance option while still covering local Docker runs and server deployment.

## Alternatives Considered

### Option A: Single production-oriented Dockerfile plus compose

Recommended.

Pros:

- simplest file layout
- production and local usage stay aligned
- minimal maintenance burden
- easy to document and support

Cons:

- development inside Docker is less ergonomic than a dedicated hot-reload setup

### Option B: Separate dev and prod Dockerfiles/compose files

Not recommended for this task.

Pros:

- better inner-loop developer experience

Cons:

- more files and divergence
- higher maintenance cost
- not justified because development container support is not the main priority

### Option C: Dockerfile only, no compose

Not recommended for this task.

Pros:

- smallest implementation footprint

Cons:

- worse usability
- pushes volume/config wiring complexity to each user
- weaker documentation story for deployment

## Proposed Changes

### 1. Add `backend/Dockerfile`

Create a production-oriented multi-stage image build.

Builder stage responsibilities:

- start from an official Python base image that supports both x86_64 and ARM64
- install `uv`
- copy `pyproject.toml` and `uv.lock`
- install application dependencies from the lockfile
- copy backend application source

Runtime stage responsibilities:

- use a slim Python base image
- copy the prepared environment and application files from the builder stage
- create and use a non-root user
- expose port `8000`
- run `uvicorn app.main:app --host 0.0.0.0 --port 8000`

The Dockerfile should be written so it builds cleanly on Apple Silicon and standard Linux CI/server environments without architecture-specific branching.

### 2. Add `backend/.dockerignore`

Exclude files that should not be sent into the Docker build context, including:

- `.venv`
- `__pycache__`
- `.pytest_cache`
- local SQLite files
- test artifacts
- editor/system junk

This reduces build context size and avoids accidentally baking local state into the image.

### 3. Add root-level `docker-compose.yml`

Create a single `backend` service with:

- build context pointing to `backend/`
- published port `8000:8000`
- mounted config directory so `backend/config/config.yaml` remains editable from the host
- mounted persistent data location for SQLite
- environment overrides for database path where needed
- health check against `/health`
- restart policy suitable for server use

The compose file should optimize for predictable startup rather than dev hot reload.

### 4. Make SQLite path explicit for containers

The current default database URL is relative: `sqlite:///./byvo.db`.

For Docker, persistence is more reliable if the database file lives at an explicit mounted path, for example under `/data/byvo.db`.

Implementation direction:

- preserve the existing settings model
- allow Docker to override `database_url` explicitly through environment variables
- set compose to use a stable mounted database path

This avoids hidden dependence on container working directory behavior.

### 5. Update documentation

Extend `README.md` with a Docker section covering:

- how to prepare `backend/config/config.yaml`
- how to build and start with `docker compose up -d --build`
- where persistent data lives
- how to stop/restart the service
- how to override config with environment variables
- note that the setup works on local machines, Linux x86_64, and Linux ARM64

## File-Level Design

### `backend/Dockerfile`

Responsibilities:

- deterministic dependency installation from `uv.lock`
- minimal runtime image
- non-root execution
- stable startup command

Expected behavior:

- `docker build` succeeds from the repository root or compose workflow
- image starts without requiring a local Python environment on the host

### `backend/.dockerignore`

Responsibilities:

- keep image builds clean and small

Expected behavior:

- local virtualenvs, caches, and database files are excluded from build context

### `docker-compose.yml`

Responsibilities:

- standard run entrypoint
- bind config and data paths
- publish service port
- define health check

Expected behavior:

- one command is enough to build and run the backend
- SQLite data survives container recreation

### `backend/app/config.py`

Potentially adjusted only if needed to support cleaner container defaults or explicit path handling.

Expected behavior:

- existing YAML and env override behavior remains intact
- Docker-provided `DATABASE_URL` or nested env override continues to work predictably

No broader config refactor is in scope.

### `README.md`

Responsibilities:

- document the Docker workflow clearly enough for first-time use

Expected behavior:

- a user can start the backend in Docker without reading source code

## Data and Persistence

SQLite remains the persistence layer.

Container persistence model:

- image is immutable
- SQLite file lives on a mounted host path or named volume
- config file remains outside the image via a bind mount

This preserves the current lightweight deployment model and avoids introducing new infrastructure.

## Security and Operations

Include low-cost production improvements:

- run as non-root inside the container
- add a health check using `GET /health`
- avoid embedding secrets in the image
- keep credentials supplied through mounted config or environment variables

Not in scope:

- TLS termination
- secrets manager integration
- reverse proxy setup

## Testing and Verification Plan

Follow behavior-first verification for the config/persistence change.

1. Add or adjust a focused backend test only if implementation changes observable config behavior.
2. Run existing backend tests.
3. Validate compose configuration with `docker compose config`.
4. Build the image.
5. Start the container with compose.
6. Verify `GET /health` succeeds.
7. Verify the SQLite database file is created under the mounted persistent path.

If an implementation path does not require app-level behavior changes, Docker build/run verification is sufficient in addition to the existing test suite.

## Risks

### Relative SQLite path mismatch

If the container relies on a relative SQLite path, persistence may land in an unexpected location.

Mitigation:

- set an explicit database path in compose

### Config path mismatch

If the container working directory or mount path does not match the app’s expected `config/config.yaml` location, startup will silently miss file-based config.

Mitigation:

- align compose bind mounts with the app’s current config discovery path
- verify startup with mounted config

### Native dependency compatibility across architectures

Some Python packages may rely on platform wheels.

Mitigation:

- use official multi-arch Python base images
- verify the image builds locally on current hardware and remains architecture-neutral in Dockerfile design

## Rollout

1. Implement Dockerfile, `.dockerignore`, compose, and docs.
2. Make the smallest config adjustment required for stable container persistence.
3. Run backend tests and Docker verification.
4. Share exact startup instructions in the README.

## Open Decisions Resolved

- Use a single production-oriented Docker workflow: yes
- Use compose: yes
- Keep SQLite: yes
- Prioritize production over hot reload: yes
- Support local, Linux x86_64, and Linux ARM64: yes
