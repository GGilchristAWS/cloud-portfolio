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
