import datetime as dt
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))
import handler  # noqa: E402

NOW = dt.datetime(2026, 10, 30, 18, 0, 0)
ARN = "arn:aws:lambda:us-west-2:123456789012:function:launcher"


@pytest.fixture(autouse=True)
def fakes(monkeypatch):
    """Replace every GitHub and AWS call; tests set the demo's state on `calls`."""
    calls = SimpleNamespace(state="down", launches=0, until=None, dispatched=[], scheduled=[])
    monkeypatch.setenv("DAILY_LIMIT", "4")
    monkeypatch.setenv("SESSION_MINUTES", "120")
    monkeypatch.setattr(handler, "demo_state", lambda: calls.state)
    monkeypatch.setattr(handler, "launches_today", lambda now: calls.launches)
    monkeypatch.setattr(handler, "teardown_time", lambda: calls.until)
    monkeypatch.setattr(handler, "dispatch", calls.dispatched.append)
    monkeypatch.setattr(handler, "schedule_teardown", lambda at, arn: calls.scheduled.append(at))
    return calls


def request(method: str, path: str = "/api/demo") -> dict:
    event = {"rawPath": path, "requestContext": {"http": {"method": method}}}
    result = handler.handler(event, SimpleNamespace(invoked_function_arn=ARN))
    return {"code": result["statusCode"], **json.loads(result["body"])}


def test_start_launches_and_schedules_teardown(fakes) -> None:
    result = handler.start(NOW, ARN)
    assert result == {"state": "starting", "until": "2026-10-30T20:00:00Z"}
    assert fakes.dispatched == ["deploy.yml"]
    assert fakes.scheduled == [NOW + dt.timedelta(hours=2)]


@pytest.mark.parametrize("state", ["starting", "up", "stopping"])
def test_start_does_nothing_unless_down(fakes, state) -> None:
    fakes.state, fakes.until = state, "2026-10-30T20:00:00Z"
    assert handler.start(NOW, ARN) == {"state": state, "until": "2026-10-30T20:00:00Z"}
    assert fakes.dispatched == []
    assert fakes.scheduled == []


def test_start_refuses_past_daily_limit(fakes) -> None:
    fakes.launches = 4
    assert handler.start(NOW, ARN)["limit_reached"] is True
    assert fakes.dispatched == []


def test_get_reports_state(fakes) -> None:
    fakes.state = "up"
    assert request("GET") == {"code": 200, "state": "up", "until": None}


def test_post_starts(fakes) -> None:
    assert request("POST")["state"] == "starting"
    assert fakes.dispatched == ["deploy.yml"]


def test_other_paths_and_methods_are_rejected(fakes) -> None:
    assert request("GET", "/api/other")["code"] == 404
    assert request("DELETE")["code"] == 405
    assert fakes.dispatched == []


def test_scheduled_teardown(fakes) -> None:
    assert handler.handler({"action": "teardown"}, None) is None
    assert fakes.dispatched == ["teardown.yml"]
