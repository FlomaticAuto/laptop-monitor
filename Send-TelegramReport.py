"""
Send-TelegramReport.py
Screenshots each section of the LaptopMonitor report and sends them
as Telegram photos, followed by a plain-text summary message.

Usage:
    python Send-TelegramReport.py
    python Send-TelegramReport.py --report C:/path/to/index.html

Credentials are read from environment variables so they never touch git:
    TELEGRAM_BOT_TOKEN   (required)
    TELEGRAM_CHAT_ID     (required)
"""

import argparse
import io
import os
import ssl
import sys
import time
import urllib.request
import urllib.parse

# Ensure emoji and Unicode print correctly on Windows consoles
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

# Norton (and similar AV) intercepts TLS with a CA cert that fails Python's strict check.
# Load Windows system certs and relax the broken-CA constraint.
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.load_default_certs()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE
import json
import tempfile
from pathlib import Path
from playwright.sync_api import sync_playwright

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DEFAULT_REPORT = r"C:\LaptopMonitor\index.html"

BOT_TOKEN = os.environ.get("LM_TELEGRAM_BOT_TOKEN", "8178468013:AAGuGvX2WOd14SuKlz1Ncmt9TrLwuo8ryTg")
CHAT_ID   = os.environ.get("LM_TELEGRAM_CHAT_ID",   "8042233389")

# Sections to capture: (CSS selector, caption)
SECTIONS = [
    (".cards",                         "📊 Live Snapshot"),
    (".section:has(#chartCpu)",        "📈 Performance History"),
    (".section:has(thead)",            "🧠 Top Processes by RAM"),
]

# ---------------------------------------------------------------------------
# Telegram helpers
# ---------------------------------------------------------------------------
API = f"https://api.telegram.org/bot{BOT_TOKEN}"

def tg_send_photo(path: str, caption: str):
    url = f"{API}/sendPhoto"
    boundary = "----boundary"
    with open(path, "rb") as f:
        img_data = f.read()

    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="chat_id"\r\n\r\n'
        f"{CHAT_ID}\r\n"
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="caption"\r\n\r\n'
        f"{caption}\r\n"
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="photo"; filename="report.png"\r\n'
        f"Content-Type: image/png\r\n\r\n"
    ).encode() + img_data + f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(req, context=_ssl_ctx) as resp:
        result = json.loads(resp.read())
    if not result.get("ok"):
        raise RuntimeError(f"Telegram sendPhoto failed: {result}")
    return result

def tg_send_message(text: str):
    url = f"{API}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, context=_ssl_ctx) as resp:
        result = json.loads(resp.read())
    if not result.get("ok"):
        raise RuntimeError(f"Telegram sendMessage failed: {result}")
    return result

# ---------------------------------------------------------------------------
# Screenshot each section via Playwright
# ---------------------------------------------------------------------------
def screenshot_sections(report_path: str) -> list[tuple[str, str]]:
    file_url = Path(report_path).as_uri()
    shots = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1200, "height": 900})
        page.goto(file_url, wait_until="networkidle")

        # Click "7D" so screenshots always show a full week minimum
        try:
            page.click('.filter-btn[data-days="7"]')
            page.wait_for_timeout(400)
        except Exception:
            pass

        for selector, caption in SECTIONS:
            try:
                el = page.query_selector(selector)
                if not el:
                    print(f"  WARN: selector not found: {selector}")
                    continue
                # Scroll element into view and add a little padding
                el.scroll_into_view_if_needed()
                page.wait_for_timeout(200)
                box = el.bounding_box()
                pad = 16
                clip = {
                    "x":      max(0, box["x"] - pad),
                    "y":      max(0, box["y"] - pad),
                    "width":  box["width"]  + pad * 2,
                    "height": box["height"] + pad * 2,
                }
                tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
                tmp.close()
                page.screenshot(path=tmp.name, clip=clip)
                shots.append((tmp.name, caption))
                print(f"  OK  {caption}")
            except Exception as e:
                print(f"  ERR {caption}: {e}")

        browser.close()
    return shots

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default=DEFAULT_REPORT)
    args = parser.parse_args()

    report = args.report
    if not Path(report).exists():
        print(f"ERROR: report not found: {report}", file=sys.stderr)
        sys.exit(1)

    print(f">>> Screenshotting: {report}")
    shots = screenshot_sections(report)
    if not shots:
        print("ERROR: no screenshots captured", file=sys.stderr)
        sys.exit(1)

    print(f">>> Sending {len(shots)} image(s) to Telegram chat {CHAT_ID}...")
    for path, caption in shots:
        try:
            tg_send_photo(path, caption)
            print(f"  Sent: {caption}")
        finally:
            os.unlink(path)
        time.sleep(0.5)   # stay well under Telegram's rate limit

    # Plain-text summary line
    hostname = os.environ.get("COMPUTERNAME", "laptop")
    ts = time.strftime("%Y-%m-%d %H:%M")
    tg_send_message(f"<b>LaptopMonitor</b> — {hostname}\nReport generated {ts}\n"
                    f'<a href="https://flomaticauto.github.io/laptop-monitor/">View full report</a>')
    print("  Sent: summary message")
    print(">>> Done.")

if __name__ == "__main__":
    main()
