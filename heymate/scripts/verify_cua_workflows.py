#!/usr/bin/env python3
"""Live checks against a synthetic AppKit target, never user documents.

Capture bytes stay in memory. Foreground escalation, when needed, targets only
the fixture. This checks invoking-host permissions, not HeyMate's TCC identity.
"""
import argparse
import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import time

from compare_cua_drivers import MCP, wait_for_state


def initialize(client):
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "heymate-broader-check", "version": "1"}})
    client.send({"method": "notifications/initialized"})


def run(driver, fixture):
    checks = []
    client = MCP(driver)
    initialize(client)
    with tempfile.TemporaryDirectory(prefix="heymate-cua-workflows-") as directory:
        state_path = Path(directory) / "state.json"
        process = subprocess.Popen([str(fixture), str(state_path)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            assert wait_for_state(state_path, lambda _: True), "fixture startup"
            windows = []
            for _ in range(30):
                listing = client.tool("list_windows", {"pid": process.pid, "on_screen_only": True})
                windows = [w for w in (listing or {}).get("windows", []) if w.get("pid") == process.pid]
                if windows:
                    break
                time.sleep(.1)
            assert len(windows) == 1, "fixture-owned window"
            window_id = windows[0]["window_id"]
            target = {"pid": process.pid, "window_id": window_id}

            def snapshot():
                return client.tool("get_window_state", {**target, "include_screenshot": False,
                    "tree_format": "both", "max_elements": 180}) or {}

            state = snapshot()
            field = next(e for e in state["elements"] if e["role"] == "AXTextField")
            slider = next(e for e in state["elements"] if e["role"] == "AXSlider")
            scroll = next(e for e in state["elements"] if e["role"] in ("AXScrollArea", "AXTextArea"))
            # Capture only the opaque synthetic window, then discard all pixels.
            capture = client.request("tools/call", {"name": "get_window_state", "arguments": {
                **target, "include_accessibility_tree": False, "include_screenshot": True,
                "full_output": True, "max_image_dimension": 0}})
            geometry = capture.get("structuredContent", {})
            images = [part for part in capture.get("content", []) if part.get("type") == "image"]
            valid = False
            dimensions = None
            if images:
                data = base64.b64decode(images[0]["data"])
                valid = data[:8] == b"\x89PNG\r\n\x1a\n"
                if valid:
                    dimensions = list(struct.unpack(">II", data[16:24]))
                del data
            checks.append({"name": "window_capture", "passed": valid and not capture.get("isError", False),
                           "dimensions": dimensions, "pixels_saved": False})
            del images, capture

            # Re-read after capture: never reuse a superseded element token.
            state = snapshot()
            field = next(e for e in state["elements"] if e["role"] == "AXTextField")
            scroll = next(e for e in state["elements"] if e["role"] in ("AXScrollArea", "AXTextArea"))
            slider = next(e for e in state["elements"] if e["role"] == "AXSlider")
            client.tool("set_value", {"pid": process.pid, "element_token": field["element_token"], "value": "Keyboard check"})
            key_result = client.tool("press_key", {**target, "element_token": field["element_token"], "key": "return"})
            submitted = wait_for_state(state_path, lambda s: s["submissions"] > 0, 1)
            keyboard_mode = "background"
            if submitted is None:
                keyboard_mode = "foreground"
                key_result = client.tool("press_key", {**target, "element_token": field["element_token"],
                    "key": "return", "delivery_mode": "foreground"})
                submitted = wait_for_state(state_path, lambda s: s["submissions"] > 0)
            checks.append({"name": "return_key_submits", "passed": submitted is not None,
                           "delivery": keyboard_mode, "tool_succeeded": key_result is not None})

            initial_scroll = json.loads(state_path.read_text())["scroll_y"]
            result = client.tool("scroll", {**target, "element_token": scroll["element_token"],
                "direction": "down", "amount": 8})
            scrolled = wait_for_state(state_path, lambda s: abs(s["scroll_y"] - initial_scroll) > 5, 1)
            scroll_mode = "background"
            if scrolled is None:
                scroll_mode = "foreground"
                result = client.tool("scroll", {**target, "element_token": scroll["element_token"],
                    "direction": "down", "amount": 8, "delivery_mode": "foreground"})
                scrolled = wait_for_state(state_path, lambda s: abs(s["scroll_y"] - initial_scroll) > 5)
            checks.append({"name": "targeted_scroll", "passed": scrolled is not None,
                           "delivery": scroll_mode, "tool_succeeded": result is not None})

            # Tree reads supersede capture authority. Re-capture immediately
            # before pixel input, just as HeyMate's drag route does.
            fresh_capture = client.request("tools/call", {"name": "get_window_state", "arguments": {
                **target, "include_accessibility_tree": False, "include_screenshot": True,
                "full_output": True, "max_image_dimension": 0}})
            geometry = fresh_capture.get("structuredContent", {})
            del fresh_capture
            bounds = geometry.get("window_bounds", {})
            scale = geometry.get("screenshot_scale", 1)
            frame = slider.get("frame", {})
            if valid and all(k in bounds for k in ("x", "y")) and all(k in frame for k in ("x", "y", "w", "h")):
                def point(fraction):
                    return ((frame["x"] + frame["w"] * fraction - bounds["x"]) * scale,
                            (frame["y"] + frame["h"] / 2 - bounds["y"]) * scale)
                start, end = point(.2), point(.8)
                drag_arguments = {**target, "from_x": start[0], "from_y": start[1],
                    "to_x": end[0], "to_y": end[1], "duration_ms": 500, "steps": 28}
                result = client.tool("drag", drag_arguments)
                dragged = wait_for_state(state_path, lambda s: s["slider"] > 60, 1)
                drag_mode = "background"
                if dragged is None:
                    drag_mode = "foreground"
                    result = client.tool("drag", {**drag_arguments, "delivery_mode": "foreground"})
                    dragged = wait_for_state(state_path, lambda s: s["slider"] > 60)
                checks.append({"name": "slider_drag", "passed": dragged is not None,
                               "delivery": drag_mode, "tool_succeeded": result is not None})
            else:
                checks.append({"name": "slider_drag", "passed": False, "reason": "capture geometry unavailable"})

            # A replaced snapshot must invalidate the old token, not act elsewhere.
            stale = field["element_token"]
            snapshot()
            result = client.tool("set_value", {"pid": process.pid, "element_token": stale, "value": "Must not land"})
            observed = json.loads(state_path.read_text())
            checks.append({"name": "stale_reference_refused", "passed": result is None and observed["text"] != "Must not land"})

            client.close()
            checks.append({"name": "owned_driver_stops", "passed": client.process.poll() is not None})
            client = MCP(driver)
            initialize(client)
            checks.append({"name": "new_session_recovers", "passed": client.tool("get_screen_size", {}) is not None})
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            client.close()
    return {"checks": checks, "passed": all(check["passed"] for check in checks),
            "limits": ["Synthetic native app; invoking-host permissions, not HeyMate's TCC identity.",
                       "Driver shutdown/restart checked; in-flight cancellation needs separate check."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, default=Path("/Applications/CuaDriver.app/Contents/MacOS/cua-driver"))
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = run(args.driver, args.fixture)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)
