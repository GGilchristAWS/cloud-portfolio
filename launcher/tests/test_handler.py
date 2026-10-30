import datetime as dt
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))
import handler  # noqa: E402

NOW = dt.datetime(2026, 10, 30, 18, 0, 0)
LATER = NOW + dt.timedelta(hours=2)


@pytest.fixture(autouse=True)
def fakes(monkeypatch):
    """Replace every GitHub and AWS call; tests set the demo's state on `calls`."""
    calls = SimpleNamespace(
        state="down",
        launches=0,
        teardown=None,
        dispatched=[],
        scheduled=[],
        cancelled=0,
        emails=[],
    )

    def schedule(at, description=handler.LAUNCHED):
        calls.scheduled.append((at, description))
        calls.teardown = {"at": at, "extended": description == handler.EXTENDED}

    monkeypatch.setenv("DAILY_LIMIT", "4")
    monkeypatch.setenv("SESSION_MINUTES", "120")
    monkeypatch.setenv("GITHUB_REPO", "owner/repo")
    monkeypatch.setattr(handler, "utc_now", lambda: NOW)
    monkeypatch.setattr(handler, "demo_state", lambda: calls.state)
    monkeypatch.setattr(handler, "launches_today", lambda now: calls.launches)
    monkeypatch.setattr(handler, "pending_teardown", lambda: calls.teardown)
    monkeypatch.setattr(handler, "dispatch", calls.dispatched.append)
    monkeypatch.setattr(handler, "schedule_teardown", schedule)
    monkeypatch.setattr(
        handler, "cancel_teardown", lambda: setattr(calls, "cancelled", calls.cancelled + 1)
    )
    monkeypatch.setattr(handler, "notify", lambda subject, lines: calls.emails.append(lines))
    return calls


def request(method: str, path: str = "/api/demo", headers: dict | None = None) -> dict:
    event = {
        "rawPath": path,
        "headers": headers or {},
        "requestContext": {"http": {"method": method}},
    }
    result = handler.handler(event, None)
    return {"code": result["statusCode"], **json.loads(result["body"])}


def test_launch_schedules_teardown_starts_deploy_and_emails(fakes) -> None:
    result = request("POST", headers={"user-agent": "Recruiter Browser", "referer": "linkedin"})
    assert result == {
        "code": 200,
        "state": "starting",
        "until": "2026-10-30T20:00:00Z",
        "can_extend": True,
    }
    assert fakes.scheduled == [(LATER, handler.LAUNCHED)]
    assert fakes.dispatched == ["deploy.yml"]
    assert "Browser: Recruiter Browser" in fakes.emails[0]
    assert "Came from: linkedin" in fakes.emails[0]


@pytest.mark.parametrize("state", ["starting", "up", "stopping"])
def test_launch_does_nothing_unless_down(fakes, state) -> None:
    fakes.state = state
    assert request("POST")["state"] == state
    assert fakes.dispatched == []
    assert fakes.scheduled == []
    assert fakes.emails == []


def test_launch_refuses_past_daily_limit(fakes) -> None:
    fakes.launches = 4
    assert request("POST")["limit_reached"] is True
    assert fakes.dispatched == []
    assert fakes.emails == []


def test_status_reports_teardown_and_extension(fakes) -> None:
    fakes.state, fakes.teardown = "up", {"at": LATER, "extended": False}
    assert request("GET") == {
        "code": 200,
        "state": "up",
        "until": "2026-10-30T20:00:00Z",
        "can_extend": True,
    }


def test_manual_deploy_without_timer_cannot_be_extended(fakes) -> None:
    fakes.state = "up"
    assert request("GET")["can_extend"] is False
    assert request("POST", "/api/demo/extend")["until"] is None
    assert fakes.scheduled == []


def test_extend_adds_an_hour_once(fakes) -> None:
    fakes.state, fakes.teardown = "up", {"at": LATER, "extended": False}
    first = request("POST", "/api/demo/extend")
    assert first["until"] == "2026-10-30T21:00:00Z"
    assert first["can_extend"] is False
    second = request("POST", "/api/demo/extend")
    assert second["until"] == "2026-10-30T21:00:00Z"
    assert fakes.scheduled == [(LATER + handler.EXTENSION, handler.EXTENDED)]


def test_extend_needs_a_running_demo(fakes) -> None:
    fakes.state, fakes.teardown = "stopping", {"at": LATER, "extended": False}
    assert request("POST", "/api/demo/extend")["can_extend"] is False
    assert fakes.scheduled == []


def test_unknown_paths_and_methods_are_rejected(fakes) -> None:
    assert request("GET", "/api/other")["code"] == 404
    assert request("DELETE")["code"] == 405
    assert request("GET", "/api/demo/extend")["code"] == 405
    assert fakes.dispatched == []


def test_scheduled_teardown(fakes) -> None:
    assert handler.handler({"action": "teardown"}, None) is None
    assert fakes.dispatched == ["teardown.yml"]


def test_manual_deploy_gets_a_timer_unless_one_is_pending(fakes) -> None:
    handler.handler({"action": "ensure_teardown"}, None)
    assert fakes.scheduled == [(LATER, handler.LAUNCHED)]
    handler.handler({"action": "ensure_teardown"}, None)
    assert len(fakes.scheduled) == 1


def test_keep_up_cancels_the_timer(fakes) -> None:
    handler.handler({"action": "cancel_teardown"}, None)
    assert fakes.cancelled == 1
    assert fakes.dispatched == []
