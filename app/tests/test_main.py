from fastapi.testclient import TestClient

from portfolio.main import app

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


def test_api_docs_are_disabled() -> None:
    assert client.get("/docs").status_code == 404
    assert client.get("/openapi.json").status_code == 404
