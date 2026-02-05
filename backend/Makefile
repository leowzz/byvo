# Backend 常用命令 (uv)

.PHONY: sync run run-dev test clean

sync:
	uv sync

run:
	uv run uvicorn app.main:app --host 0.0.0.0 --port 8000

run-dev:
	uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:
	uv run pytest -v

clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true

# 默认目标
.DEFAULT_GOAL := run-dev
