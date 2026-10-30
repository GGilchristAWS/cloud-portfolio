"""Check the published resume end to end, as a visitor's browser sees it.

Loads the page in headless Chromium and waits for the demo panel to report a
state from the launcher (CloudFront -> Lambda -> GitHub). Fails if the panel
says the launcher is unavailable, or never answers. Run by deploy.yml after
each upload:

    uv run --with playwright==1.55.0 python scripts/check_site.py <url>
"""

import sys

from playwright.sync_api import sync_playwright

CHECKING = "Checking whether"
UNAVAILABLE = "unavailable"


def check(url: str) -> str:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        errors: list[str] = []
        page.on("pageerror", lambda err: errors.append(str(err)))
        page.goto(url, wait_until="load")
        status = page.locator("#demo-status")
        status.filter(has_not_text=CHECKING).wait_for(timeout=20_000)
        text = status.inner_text()
        browser.close()
    if errors:
        raise SystemExit(f"Script errors on {url}: {errors}")
    if UNAVAILABLE in text:
        raise SystemExit(f"The demo launcher is unavailable: {text!r}")
    return text


if __name__ == "__main__":
    print(f"Demo panel: {check(sys.argv[1])}")
