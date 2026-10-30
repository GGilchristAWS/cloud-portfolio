import sys
from pathlib import Path

from fastapi.testclient import TestClient

from portfolio.main import app, resume

client = TestClient(app)


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_version_reports_build_info() -> None:
    response = client.get("/version")
    assert response.status_code == 200
    assert set(response.json()) == {"version", "commit", "build_time"}


def test_index_renders_runtime_panel() -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "Served by" in response.text
    assert "local" in response.text  # no ECS metadata endpoint outside ECS


def test_index_links_to_resume() -> None:
    assert 'href="/resume"' in client.get("/").text


def test_resume_data_is_complete() -> None:
    data = resume()
    assert data["profile"]["name"]
    assert data["experience"], "at least one job"
    for job in data["experience"]:
        assert job["title"] and job["company"] and job["dates"], job
        assert job["highlights"], f"{job['company']} has no highlights"
        for engagement in job.get("engagements", []):
            assert engagement["who"] and engagement["what"], engagement
    for group in data["skills"]:
        assert group["area"] and group["items"], group


def test_resume_renders_every_job() -> None:
    response = client.get("/resume")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    for job in resume()["experience"]:
        assert job["company"] in response.text
    assert "Technical skills" in response.text


def test_api_docs_are_disabled() -> None:
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404


TOKEN = {"X-Load-Test-Token": "test-token"}


def test_simulate_is_hidden_without_a_token(monkeypatch) -> None:
    monkeypatch.delenv("LOAD_TEST_TOKEN", raising=False)
    assert client.get("/api/simulate", headers=TOKEN).status_code == 404


def test_simulate_rejects_a_wrong_token_before_validating(monkeypatch) -> None:
    monkeypatch.setenv("LOAD_TEST_TOKEN", "test-token")
    wrong = {"X-Load-Test-Token": "nope"}
    assert client.get("/api/simulate?latency_ms=999999", headers=wrong).status_code == 404


def test_simulate_caps_its_parameters(monkeypatch) -> None:
    monkeypatch.setenv("LOAD_TEST_TOKEN", "test-token")
    for query in ("latency_ms=2001", "jitter_ms=1001", "error_rate=0.6", "latency_ms=-1"):
        assert client.get(f"/api/simulate?{query}", headers=TOKEN).status_code == 422, query


def test_simulate_succeeds_or_fails_as_asked(monkeypatch) -> None:
    monkeypatch.setenv("LOAD_TEST_TOKEN", "test-token")
    headers = {**TOKEN, "X-Load-Test-Scenario": "spike"}
    ok = client.get("/api/simulate?latency_ms=5", headers=headers)
    assert ok.status_code == 200
    assert ok.json() == {"scenario": "spike", "delay_ms": 5}

    monkeypatch.setattr("portfolio.main.random.random", lambda: 0.0)
    assert client.get("/api/simulate?error_rate=0.5", headers=headers).status_code == 500


def test_simulate_buckets_unknown_scenarios(monkeypatch) -> None:
    monkeypatch.setenv("LOAD_TEST_TOKEN", "test-token")
    headers = {**TOKEN, "X-Load-Test-Scenario": "made-up-name"}
    assert client.get("/api/simulate", headers=headers).json()["scenario"] == "other"


def test_static_site_has_resume_and_launcher(tmp_path) -> None:
    sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
    import build_site

    build_site.build(tmp_path)
    page = (tmp_path / "index.html").read_text()
    assert resume()["profile"]["name"] in page
    assert 'id="demo-launch"' in page
    assert 'href="/resume"' not in page  # the static site has only this page
    assert 'id="how-it-works"' in page
    assert "walkthrough" not in page  # no media configured yet
    offline = (tmp_path / build_site.OFFLINE_PAGE).read_text()
    assert "demo is off" in offline
    assert f'href="{build_site.SITE_URL}"' in offline


def test_static_site_shows_configured_media(tmp_path) -> None:
    sys.path.insert(0, str(Path(__file__).parent.parent / "scripts"))
    import build_site

    shot = build_site.SITE_DIR / "test-shot.webp"
    shot.write_bytes(b"webp")
    try:
        media = {
            "walkthrough_url": "https://example.com/tour",
            "screenshots": [{"file": shot.name, "caption": "Dashboards"}],
        }
        build_site.build(tmp_path, media)
    finally:
        shot.unlink()
    page = (tmp_path / "index.html").read_text()
    assert 'href="https://example.com/tour"' in page
    assert 'src="media/test-shot.webp"' in page
    assert 'id="shot-viewer"' in page  # screenshots open over the page
    assert (tmp_path / "media" / "test-shot.webp").exists()


def test_demo_resume_has_no_launcher() -> None:
    assert 'id="demo-launch"' not in client.get("/resume").text
