"""Portfolio web app served from ECS Fargate."""

import asyncio
import json
import logging
import os
import random
import secrets
import tomllib
import urllib.request
from functools import lru_cache
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from opentelemetry import metrics, trace

# Baked into the image at build time by CI.
BUILD_INFO = {
    "version": os.getenv("APP_VERSION", "dev"),
    "commit": os.getenv("GIT_SHA", "local"),
    "build_time": os.getenv("BUILD_TIME", "unknown"),
}

REPO_URL = "https://github.com/GGilchristAWS/cloud-portfolio"
GRAFANA_URL = "https://grafana.portfolio.geoffgilchrist.com"

PACKAGE_DIR = Path(__file__).parent

templates = Jinja2Templates(directory=PACKAGE_DIR / "templates")
templates.env.globals.update(repo_url=REPO_URL, grafana_url=GRAFANA_URL)
app = FastAPI(title="cloud-portfolio", docs_url=None, redoc_url=None, openapi_url=None)


@lru_cache(maxsize=1)
def runtime_info() -> dict[str, str]:
    """Where this container is running, from the ECS task metadata endpoint (v4)."""
    info = {"platform": "local", "task": "-", "zone": "-", "revision": "-"}
    uri = os.getenv("ECS_CONTAINER_METADATA_URI_V4")
    if not uri:
        return info
    try:
        # Link-local endpoint injected by the ECS agent, not user input.
        with urllib.request.urlopen(f"{uri}/task", timeout=1) as resp:  # noqa: S310
            task = json.load(resp)
    except (OSError, ValueError):
        return info
    return {
        "platform": f"ECS {task.get('LaunchType', '?')}",
        "task": task.get("TaskARN", "-").rsplit("/", 1)[-1][:12],
        "zone": task.get("AvailabilityZone", "-"),
        "revision": f"{task.get('Family', '?')}:{task.get('Revision', '?')}",
    }


@lru_cache(maxsize=1)
def resume() -> dict:
    """Resume content, edited in resume.toml and rendered by /resume."""
    with (PACKAGE_DIR / "resume.toml").open("rb") as f:
        return tomllib.load(f)


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(
        request,
        "index.html",
        {"page": "home", "build": BUILD_INFO, "runtime": runtime_info()},
    )


@app.get("/resume", response_class=HTMLResponse)
def resume_page(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(
        request,
        "resume.html",
        {"page": "resume", "resume": resume()},
    )


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/version")
def version() -> dict[str, str]:
    return BUILD_INFO


# --- Load testing ------------------------------------------------------------
# /api/simulate answers with a chosen latency and error rate, so the k6
# scenarios in loadtest/ can show the dashboards and alerts reacting. The real
# pages are too fast and reliable to ever trip them. It's public, so it only
# answers callers holding the token (a GitHub Actions secret), and its
# parameters are capped. Its traffic is told apart from real traffic by its
# http_route label.

LOAD_TEST_SCENARIOS = frozenset({"smoke", "ramp", "spike", "soak", "art"})

logger = logging.getLogger("portfolio")
load_test_requests = metrics.get_meter("portfolio").create_counter(
    "load_test.requests", description="Requests to /api/simulate, by load-test scenario."
)


def require_load_test_token(
    x_load_test_token: Annotated[str | None, Header()] = None,
) -> None:
    """Hide the endpoint (404) unless the caller presents the load-test token.

    Runs as a dependency, before query validation, so a caller without the
    token can't learn that the endpoint exists from a 422.
    """
    expected = os.getenv("LOAD_TEST_TOKEN")
    if not (expected and x_load_test_token and secrets.compare_digest(x_load_test_token, expected)):
        raise HTTPException(status_code=404)


@app.get("/api/simulate", dependencies=[Depends(require_load_test_token)])
async def simulate(
    latency_ms: Annotated[int, Query(ge=0, le=2000)] = 0,
    jitter_ms: Annotated[int, Query(ge=0, le=1000)] = 0,
    error_rate: Annotated[float, Query(ge=0, le=0.5)] = 0.0,
    x_load_test_scenario: Annotated[str | None, Header()] = None,
) -> JSONResponse:
    # Only known names become a metric label; anything else would let a caller
    # create unbounded label values (cardinality) in Prometheus.
    scenario = x_load_test_scenario if x_load_test_scenario in LOAD_TEST_SCENARIOS else "other"
    trace.get_current_span().set_attribute("load_test.scenario", scenario)
    load_test_requests.add(1, {"scenario": scenario})

    # Not cryptographic: just shaping synthetic traffic.
    delay_ms = max(0.0, latency_ms + random.uniform(-jitter_ms, jitter_ms))  # noqa: S311
    await asyncio.sleep(delay_ms / 1000)  # async, so waiting holds no worker

    if random.random() < error_rate:  # noqa: S311
        logger.warning("Simulated failure for load-test scenario %s", scenario)
        return JSONResponse({"error": "simulated failure", "scenario": scenario}, status_code=500)
    return JSONResponse({"scenario": scenario, "delay_ms": round(delay_ms)})
