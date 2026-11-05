#!/usr/bin/env python3
"""Exercise Cua's typed browser surface in its own throwaway Chrome profile."""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
from urllib.parse import parse_qs, urlparse

from compare_cua_drivers import MCP
from verify_cua_workflows import initialize


def run():
    observed = {"saved": None, "scroll": False, "clicks": 0}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/event":
                values = parse_qs(url.query)
                if "saved" in values:
                    observed["saved"] = values["saved"][0]
                    observed["clicks"] += 1
                if "scroll" in values:
                    observed["scroll"] = True
                content = b"ok"
            else:
                content = b'''<!doctype html><title>HeyMate isolated browser check</title>
                <label>Benchmark name <input id="name"></label>
                <button onclick="fetch('/event?saved='+encodeURIComponent(document.querySelector('input').value));document.querySelector('#out').textContent='Saved'">Save fixture</button>
                <p id="out"></p><div style="height:2200px"></div><p>Fixture bottom</p>
                <script>onscroll=()=>fetch('/event?scroll=yes')</script>'''
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    client = MCP(Path("/Applications/CuaDriver.app/Contents/MacOS/cua-driver"))
    initialize(client)
    session = "heymate-typed-browser-regression"
    checks = []
    try:
        prepared = client.tool("browser_prepare", {"session": session, "allow_launch": True,
                               "profile": {"mode": "isolated_new"}})
        assert prepared and prepared.get("prepared"), "isolated launch refused"
        checks.append({"name": "isolated_profile_launch", "passed": prepared["side_effects"].get("copied_profile_data") is False})
        pid = prepared["prepared_pid"]
        listing = client.tool("list_windows", {"pid": pid})
        window = next(w for w in listing["windows"] if w["pid"] == pid)
        bound = client.tool("get_browser_state", {"pid": pid, "window_id": window["window_id"], "session": session})
        assert bound and bound.get("binding_quality") == "exact", "browser binding not exact"
        checks.append({"name": "exact_window_binding", "passed": True})
        target = {"session": session, "target_id": bound["target_id"], "tab_id": bound["tabs"][0]["tab_id"]}
        url = f"http://127.0.0.1:{server.server_port}/form"
        navigated = client.tool("browser_navigate", {**target, "url": url})
        assert navigated is not None, "fixture navigation failed"
        checks.append({"name": "navigate_local_fixture", "passed": True})

        def snapshot():
            return client.tool("get_browser_state", target) or {}

        state = snapshot()
        field = next((row["ref"] for row in state.get("refs", [])
                      if row.get("node") == "input" and row.get("label") == "id=name"), None)
        if not field:
            raise AssertionError("field ref missing; snapshot keys=" + str(sorted(state)))
        typed = client.tool("browser_type", {**target, "ref": field, "text": "Synthetic Chrome value", "replace": True})
        state = snapshot()
        buttons = [row["ref"] for row in state.get("refs", []) if row.get("node") == "button"]
        button = buttons[0] if len(buttons) == 1 else None
        assert button, "button ref missing"
        clicked = client.tool("browser_click", {**target, "ref": button})
        deadline = time.monotonic() + 3
        while observed["saved"] is None and time.monotonic() < deadline:
            time.sleep(.05)
        checks.append({"name": "type_click_verified_by_page_event", "passed": typed is not None and clicked is not None and observed["saved"] == "Synthetic Chrome value"})
        moved = client.tool("browser_pointer", {**target, "action": "scroll", "x": 100, "y": 250, "delta_y": 500})
        deadline = time.monotonic() + 2
        while not observed["scroll"] and time.monotonic() < deadline:
            time.sleep(.05)
        checks.append({"name": "page_scroll_event", "passed": moved is not None and observed["scroll"]})
        result = client.request("tools/call", {"name": "get_browser_state", "arguments": {**target, "include_screenshot": True}})
        images = [part for part in result.get("content", []) if part.get("type") == "image"]
        png = bool(images) and base64.b64decode(images[0]["data"]).startswith(b"\x89PNG")
        checks.append({"name": "tab_capture_in_memory", "passed": png, "pixels_saved": False})
        del images, result
        navigated = client.tool("browser_navigate", {**target, "url": url + "?fresh=1"})
        before_clicks = observed["clicks"]
        stale = client.request("tools/call", {"name": "browser_click", "arguments": {**target, "ref": button}})
        time.sleep(.2)
        detail = stale.get("structuredContent", {})
        refused = stale.get("isError") is True or detail.get("status") in ("error", "refused") or detail.get("effect") == "refused"
        checks.append({"name": "navigation_invalidates_old_ref", "passed": navigated is not None and refused and observed["clicks"] == before_clicks,
                       "refusal_code": (detail.get("error") or {}).get("code")})
    finally:
        ended = client.tool("end_session", {"session": session})
        checks.append({"name": "owned_browser_session_ends", "passed": ended is not None and ended.get("active") is False})
        client.close()
        server.shutdown()
        server.server_close()
    return {"checks": checks, "passed": all(check["passed"] for check in checks),
            "limits": ["Driver-owned temporary profile only; no existing Chrome profile or sign-in tested.",
                       "browser_prepare remains outside HeyMate's agent allowlist; used only by trusted test setup."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = run()
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)
