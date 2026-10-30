"""Render the resume as the static site's page (bootstrap/site.tf), with the demo launcher.

It uses the app's own templates and resume.toml, so the static resume and the
demo's /resume page can't drift apart. Optional media (a walkthrough link,
screenshots) comes from site/media.toml. CI uploads the output to S3.

    uv run python scripts/build_site.py <out-dir>
"""

import shutil
import sys
import tomllib
from pathlib import Path

from portfolio.main import resume, templates

DEMO_URL = "https://demo.portfolio.geoffgilchrist.com"
SITE_DIR = Path(__file__).parent.parent / "site"


def load_media() -> dict:
    with (SITE_DIR / "media.toml").open("rb") as f:
        return tomllib.load(f)


def build(out: Path, media: dict | None = None) -> None:
    media = load_media() if media is None else media
    page = templates.get_template("resume.html").render(
        page="resume", resume=resume(), static=True, demo_url=DEMO_URL, media=media
    )
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(page, encoding="utf-8")
    for shot in media.get("screenshots", []):
        (out / "media").mkdir(exist_ok=True)
        shutil.copy2(SITE_DIR / shot["file"], out / "media" / shot["file"])


if __name__ == "__main__":
    build(Path(sys.argv[1]))
