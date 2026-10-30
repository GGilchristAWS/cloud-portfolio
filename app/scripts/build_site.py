"""Render the resume as the static site's page (bootstrap/site.tf), with the demo launcher.

It uses the app's own templates and resume.toml, so the static resume and the
demo's /resume page can't drift apart. CI uploads the output to S3.

    uv run python scripts/build_site.py <out-dir>
"""

import sys
from pathlib import Path

from portfolio.main import resume, templates

DEMO_URL = "https://demo.portfolio.geoffgilchrist.com"


def build(out: Path) -> None:
    page = templates.get_template("resume.html").render(
        page="resume", resume=resume(), static=True, demo_url=DEMO_URL
    )
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(page, encoding="utf-8")


if __name__ == "__main__":
    build(Path(sys.argv[1]))
