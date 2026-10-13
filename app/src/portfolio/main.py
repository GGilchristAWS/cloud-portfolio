"""Portfolio web app served from ECS Fargate."""

import json
import os
import tomllib
import urllib.request
from functools import lru_cache
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

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
