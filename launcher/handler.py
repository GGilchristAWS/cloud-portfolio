"""Launches the on-demand demo from the resume page and tears it down later.

Three callers (see bootstrap/launcher.tf):

  CloudFront -> function URL, from the resume page:
    GET  /api/demo         the demo's state (down, starting, up or stopping),
                           when it will be torn down, and whether it can be extended
    POST /api/demo         start it, if it is down and today's launch cap allows;
                           emails the owner
    POST /api/demo/extend  push the teardown back an hour, once per launch
  EventBridge Scheduler, a session length after a launch:
    {"action": "teardown"}
  The Deploy and Keep up workflows (scripts/launcher-action.sh):
    {"action": "ensure_teardown"}  a manual deploy: schedule a teardown unless one is pending
    {"action": "cancel_teardown"}  keep the demo up until Teardown is run by hand

Starting and stopping run the repository's Deploy and Teardown workflows, so
the demo is built exactly as a manual deploy builds it. The only state kept
here is the one-time teardown schedule (its description records an
extension); everything else is read from GitHub and from the demo itself.
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
EXTENSION = dt.timedelta(hours=1)
LAUNCHED, EXTENDED = "launched", "extended"  # the schedule's description

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def env(name: str) -> str:
    return os.environ[name]


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.UTC).replace(microsecond=0, tzinfo=None)


def iso(at: dt.datetime) -> str:
    return f"{at:%Y-%m-%dT%H:%M:%S}Z"


@cache
def aws(service: str):
    # boto3 ships with the Lambda runtime; imported here so tests run without it.
    import boto3

    return boto3.client(service)


# --- GitHub --------------------------------------------------------------------


@cache
def github_token() -> str:
    param = aws("ssm").get_parameter(Name=env("TOKEN_PARAMETER"), WithDecryption=True)
    return param["Parameter"]["Value"].strip()  # a token saved from a file ends in a newline


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


# --- The demo and its teardown schedule ----------------------------------------


def is_healthy() -> bool:
    try:
        with urllib.request.urlopen(f"{env('DEMO_URL')}/health", timeout=3) as resp:  # noqa: S310
            return resp.status == 200
    except (OSError, ValueError):
        return False


def pending_teardown() -> dict | None:
    """The pending teardown, as {"at": datetime (UTC), "extended": bool}, or None."""
    scheduler = aws("scheduler")
    try:
        schedule = scheduler.get_schedule(Name=env("SCHEDULE_NAME"))
    except scheduler.exceptions.ResourceNotFoundException:
        return None
    # The expression is "at(2026-10-30T02:30:00)", in UTC.
    at = dt.datetime.fromisoformat(schedule["ScheduleExpression"][3:-1])
    return {"at": at, "extended": schedule.get("Description") == EXTENDED}


def schedule_teardown(at: dt.datetime, description: str = LAUNCHED) -> None:
    scheduler = aws("scheduler")
    schedule = {
        "Name": env("SCHEDULE_NAME"),
        "Description": description,
        "ScheduleExpression": f"at({at:%Y-%m-%dT%H:%M:%S})",
        "ScheduleExpressionTimezone": "UTC",
        "FlexibleTimeWindow": {"Mode": "OFF"},
        "ActionAfterCompletion": "DELETE",
        "Target": {
            "Arn": env("FUNCTION_ARN"),
            "RoleArn": env("SCHEDULER_ROLE_ARN"),
            "Input": json.dumps({"action": "teardown"}),
        },
    }
    try:
        scheduler.create_schedule(**schedule)
    except scheduler.exceptions.ConflictException:
        scheduler.update_schedule(**schedule)
    logger.info("Teardown scheduled for %s (%s)", iso(at), description)


def cancel_teardown() -> None:
    scheduler = aws("scheduler")
    try:
        scheduler.delete_schedule(Name=env("SCHEDULE_NAME"))
    except scheduler.exceptions.ResourceNotFoundException:
        return
    logger.info("Teardown cancelled; the demo stays up until Teardown is run")


def notify(subject: str, lines: list[str]) -> None:
    aws("sns").publish(TopicArn=env("ALERTS_TOPIC_ARN"), Subject=subject, Message="\n".join(lines))


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


# --- Actions -------------------------------------------------------------------


def status(state: str | None = None) -> dict:
    state = state or demo_state()
    teardown = pending_teardown() if state in ("starting", "up") else None
    return {
        "state": state,
        "until": iso(teardown["at"]) if teardown else None,
        "can_extend": bool(teardown) and not teardown["extended"],
    }


def start(now: dt.datetime, visitor: dict) -> dict:
    state = demo_state()
    if state != "down":
        return status(state)
    if launches_today(now) >= int(env("DAILY_LIMIT")):
        return {"state": "down", "until": None, "can_extend": False, "limit_reached": True}

    until = now + dt.timedelta(minutes=int(env("SESSION_MINUTES")))
    schedule_teardown(until)
    dispatch(DEPLOY)
    notify(
        "Portfolio demo launched",
        [
            f"Someone launched the demo at {iso(now)}. It is torn down at {iso(until)}.",
            "",
            f"Browser: {visitor.get('user-agent', 'unknown')}",
            f"Came from: {visitor.get('referer', 'unknown')}",
            "",
            f"Deploy runs: https://github.com/{env('GITHUB_REPO')}/actions/workflows/{DEPLOY}",
        ],
    )
    return {"state": "starting", "until": iso(until), "can_extend": True}


def extend() -> dict:
    current = status()
    if current["can_extend"]:
        teardown = pending_teardown()
        schedule_teardown(teardown["at"] + EXTENSION, EXTENDED)
        current.update(until=iso(teardown["at"] + EXTENSION), can_extend=False)
    return current


def ensure_teardown(now: dt.datetime) -> None:
    """A manual deploy gets the same timer as a launch, unless one is pending."""
    if pending_teardown() is None:
        schedule_teardown(now + dt.timedelta(minutes=int(env("SESSION_MINUTES"))))


def response(code: int, body: dict) -> dict:
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


ROUTES = {
    ("GET", "/api/demo"): lambda event: status(),
    ("POST", "/api/demo"): lambda event: start(utc_now(), event.get("headers", {})),
    ("POST", "/api/demo/extend"): lambda event: extend(),
}


# Errors (an expired GitHub token, most likely) are left to raise: the
# function URL then answers 502, which the page reports, the Lambda Errors
# metric trips the launcher's alarm, and Scheduler retries a failed teardown.
def handler(event: dict, context) -> dict | None:
    action = event.get("action")
    if action == "teardown":
        dispatch(TEARDOWN)
        return None
    if action == "ensure_teardown":
        ensure_teardown(utc_now())
        return None
    if action == "cancel_teardown":
        cancel_teardown()
        return None

    method = event.get("requestContext", {}).get("http", {}).get("method")
    path = event.get("rawPath")
    route = ROUTES.get((method, path))
    if route:
        return response(200, route(event))
    if any(p == path for _, p in ROUTES):
        return response(405, {"error": "method not allowed"})
    return response(404, {"error": "not found"})
