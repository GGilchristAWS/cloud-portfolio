# syntax=docker/dockerfile:1

# --- Build: resolve the locked dependencies into a virtualenv ---------------
FROM python:3.14-slim AS build

COPY --from=ghcr.io/astral-sh/uv:0.13.0 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Dependencies first so this layer is cached across code-only changes.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project

COPY src ./src
RUN uv sync --locked --no-dev --no-editable

# --- Runtime: only the virtualenv, running as a non-root user ---------------
FROM python:3.14-slim

ARG APP_VERSION=dev
ARG GIT_SHA=local
ARG BUILD_TIME=unknown

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=$APP_VERSION \
    GIT_SHA=$GIT_SHA \
    BUILD_TIME=$BUILD_TIME

# OpenTelemetry stays off unless the runtime turns it on (the ECS task does)
# and points it at a collector with OTEL_EXPORTER_OTLP_ENDPOINT.
ENV OTEL_SDK_DISABLED=true \
    OTEL_SERVICE_NAME=portfolio-app \
    OTEL_SEMCONV_STABILITY_OPT_IN=http \
    OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true \
    OTEL_PYTHON_EXCLUDED_URLS=health

RUN useradd --system --uid 10001 --no-create-home app

COPY --from=build /app/.venv /app/.venv

USER 10001
EXPOSE 8000

# opentelemetry-instrument wraps the server with auto-instrumentation (traces,
# metrics and logs) configured entirely from the OTEL_* environment.
CMD ["opentelemetry-instrument", "uvicorn", "portfolio.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
