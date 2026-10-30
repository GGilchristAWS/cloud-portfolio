"""Launches the on-demand demo from the resume page and tears it down later.

Two callers (see bootstrap/launcher.tf):

  CloudFront -> function URL, from the resume page's launch button:
    GET  /api/demo   the demo's state: down, starting, up or stopping
    POST /api/demo   start it, if it is down and today's launch cap allows
  EventBridge Scheduler, a session length after a launch:
    {"action": "teardown"}

Starting and stopping run the repository's Deploy and Teardown workflows, so
the demo is built exactly as a manual deploy builds it. The only state kept
here is the one-time teardown schedule; everything else is read from GitHub
and from the demo itself.
"""

import datetime as dt
import json
import logging
import os
import urllib.parse
import urllib.request
from functools import cache

GITHUB_API = "https://api.github.com"
DEPLOY = "deploy.yml"
TEARDOWN = "teardown.yml"
ACTIVE = frozenset({"queued", "in_progress", "waiting", "requested", "pending"})

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def env(name: str) -> str:
    return os.environ[name]


@cache
def aws(service: str):
    # boto3 ships with the Lambda runtime; imported here so tests run without it.
    import boto3

    return boto3.client(service)


@cache
def github_token() -> str:
    param = aws("ssm").get_parameter(Name=env("TOKEN_PARAMETER"), WithDecryption=True)
    return param["Parameter"]["Value"]


def github(method: str, path: str, body: dict | None = None) -> dict:
    request = urllib.request.Request(  # noqa: S310 (fixed https URL)
        f"{GITHUB_API}/repos/{env('GITHUB_REPO')}{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {github_token()}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=5) as resp:  # noqa: S310
        payload = resp.read()
    return json.loads(payload) if payload else {}


def runs(workflow: str, **query: str | int) -> dict:
    return github("GET", f"/actions/workflows/{workflow}/runs?{urllib.parse.urlencode(query)}")


def is_running(workflow: str, **query: str) -> bool:
    recent = runs(workflow, per_page=5, **query)["workflow_runs"]
    return any(run["status"] in ACTIVE for run in recent)


def launches_today(now: dt.datetime) -> int:
    """Deploys started by hand or by this launcher since midnight UTC.

    Pushes to main never count: they deploy only while the demo is already up.
    """
    query = {"event": "workflow_dispatch", "created": f">={now:%Y-%m-%d}", "per_page": 1}
    return runs(DEPLOY, **query)["total_count"]


def dispatch(workflow: str) -> None:
    github("POST", f"/actions/workflows/{workflow}/dispatches", {"ref": "main"})
    logger.info("Started %s", workflow)


def is_healthy() -> bool:
    try:
        with urllib.request.urlopen(f"{env('DEMO_URL')}/health", timeout=3) as resp:  # noqa: S310
            return resp.status == 200
    except (OSError, ValueError):
        return False


def teardown_time() -> str | None:
    """When the pending teardown fires (ISO 8601, UTC), or None if none is pending."""
    scheduler = aws("scheduler")
    try:
        schedule = scheduler.get_schedule(Name=env("SCHEDULE_NAME"))
    except scheduler.exceptions.ResourceNotFoundException:
        return None
    # The expression is "at(2026-10-30T02:30:00)", in UTC.
    return schedule["ScheduleExpression"][3:-1] + "Z"


def schedule_teardown(at: dt.datetime, function_arn: str) -> None:
    scheduler = aws("scheduler")
    schedule = {
        "Name": env("SCHEDULE_NAME"),
        "ScheduleExpression": f"at({at:%Y-%m-%dT%H:%M:%S})",
        "ScheduleExpressionTimezone": "UTC",
        "FlexibleTimeWindow": {"Mode": "OFF"},
        "ActionAfterCompletion": "DELETE",
        "Target": {
            "Arn": function_arn,
            "RoleArn": env("SCHEDULER_ROLE_ARN"),
            "Input": json.dumps({"action": "teardown"}),
        },
    }
    try:
        scheduler.create_schedule(**schedule)
    except scheduler.exceptions.ConflictException:
        scheduler.update_schedule(**schedule)


def demo_state() -> str:
    # A teardown waits for a running deploy (shared concurrency group), so
    # check it first. Only dispatched deploys bring the demo up; a push to
    # main while it's down just builds images.
    if is_running(TEARDOWN):
        return "stopping"
    if is_healthy():
        return "up"
    if is_running(DEPLOY, event="workflow_dispatch"):
        return "starting"
    return "down"


def status() -> dict:
    return {"state": demo_state(), "until": teardown_time()}


def start(now: dt.datetime, function_arn: str) -> dict:
    state = demo_state()
    if state != "down":
        return {"state": state, "until": teardown_time()}
    if launches_today(now) >= int(env("DAILY_LIMIT")):
        return {"state": "down", "until": None, "limit_reached": True}

    until = now + dt.timedelta(minutes=int(env("SESSION_MINUTES")))
    schedule_teardown(until, function_arn)
    dispatch(DEPLOY)
    return {"state": "starting", "until": f"{until:%Y-%m-%dT%H:%M:%S}Z"}


def response(code: int, body: dict) -> dict:
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


# Errors (an expired GitHub token, most likely) are left to raise: the
# function URL then answers 502, which the page reports, the Lambda Errors
# metric trips the launcher's alarm, and Scheduler retries a failed teardown.
def handler(event: dict, context) -> dict | None:
    if event.get("action") == "teardown":
        dispatch(TEARDOWN)
        return None

    http = event.get("requestContext", {}).get("http", {})
    if event.get("rawPath") != "/api/demo":
        return response(404, {"error": "not found"})

    if http.get("method") == "GET":
        return response(200, status())
    if http.get("method") == "POST":
        now = dt.datetime.now(dt.UTC).replace(microsecond=0, tzinfo=None)
        return response(200, start(now, context.invoked_function_arn))
    return response(405, {"error": "method not allowed"})
