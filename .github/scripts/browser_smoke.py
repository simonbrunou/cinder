import os
import re
from pathlib import Path

from playwright.sync_api import expect, sync_playwright


BASE_URL = os.environ.get("CINDER_SMOKE_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
EMAIL = os.environ["CINDER_SMOKE_EMAIL"]
PASSWORD = os.environ["CINDER_SMOKE_PASSWORD"]
BOOTSTRAP_TOKEN = os.environ["CINDER_SMOKE_BOOTSTRAP_TOKEN"]
SCREENSHOT_DIR = os.environ.get("CINDER_SMOKE_SCREENSHOT_DIR")
BROWSER_CHANNEL = os.environ.get("CINDER_SMOKE_BROWSER_CHANNEL")


def wait_for_liveview(page):
    expect(page.locator("[data-phx-main].phx-connected")).to_have_count(1, timeout=10_000)


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True, channel=BROWSER_CHANNEL)
    page = browser.new_page(
        viewport={"width": 1440, "height": 900},
        color_scheme="light",
        reduced_motion="reduce",
    )
    browser_errors = []
    page.on(
        "console",
        lambda message: (
            browser_errors.append(message.text) if message.type == "error" else None
        ),
    )
    page.on("pageerror", lambda error: browser_errors.append(str(error)))

    response = page.goto(f"{BASE_URL}/users/register", wait_until="networkidle")
    assert response and response.ok, "registration page did not render"
    expect(page.locator("#registration_form")).to_be_visible()
    wait_for_liveview(page)
    assert page.evaluate(
        """() =>
          [...document.styleSheets].some(sheet => sheet.href?.includes('/assets/')) &&
          [...document.scripts].some(script => script.src.includes('/assets/'))
        """
    ), "compiled CSS and JavaScript assets did not load"

    page.locator("#user_email").fill(EMAIL)
    page.locator("#user_password").fill(PASSWORD)
    page.locator("#user_password_confirmation").fill(PASSWORD)
    page.locator("#bootstrap-token").fill(BOOTSTRAP_TOKEN)
    page.get_by_role("button", name="Create an account", exact=True).click()
    expect(page.locator("#registration-confirmation")).to_contain_text(
        "Your admin account is ready."
    )

    page.get_by_role("link", name="Log in", exact=True).click()
    expect(page).to_have_url(re.compile(r"/users/log-in$"))
    login_form = page.locator("#login_form_password")
    expect(login_form).to_be_visible()
    wait_for_liveview(page)
    login_form.get_by_label("Email", exact=True).fill(EMAIL)
    login_form.get_by_label("Password", exact=True).fill(PASSWORD)
    page.get_by_role("button", name="Log in only this time", exact=True).click()

    expect(page).to_have_url(re.compile(r"/$"), timeout=15_000)
    expect(page.get_by_role("heading", name="Discover", exact=True)).to_be_visible()
    wait_for_liveview(page)

    page.get_by_role("link", name="Dashboard", exact=True).click()
    expect(page).to_have_url(re.compile(r"/dashboard$"))
    expect(page.locator("#dashboard-health")).to_be_visible()
    wait_for_liveview(page)

    if SCREENSHOT_DIR:
        output = Path(SCREENSHOT_DIR)
        output.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=output / "dashboard.png", full_page=True)

    page.get_by_role("link", name="Library", exact=True).click()
    expect(page).to_have_url(re.compile(r"/library$"))
    expect(page.locator("main#main")).to_contain_text("Library")
    wait_for_liveview(page)

    if SCREENSHOT_DIR:
        page.screenshot(path=Path(SCREENSHOT_DIR) / "library.png", full_page=True)

    assert not browser_errors, "browser errors: " + " | ".join(browser_errors)
    browser.close()
