#!/usr/bin/env python3
"""Compare two reviewed Cua binaries without installing or touching user documents.

Uses HeyMate's embedded MCP arguments. Permission checks never prompt; no
screenshots, app names, window contents, or credentials enter the report.
Timing measures screen-size calls, not end-to-end agent performance.
"""

import argparse
import json
import math
import os
from pathlib import Path
import queue
import re
import subprocess
import tempfile
import threading
import time


class MCP:
    def __init__(self, executable):
        environment = dict(os.environ)
        for key in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY"):
            environment.pop(key, None)
        environment.update(CUA_DRIVER_EMBEDDED="1",
                           CUA_DRIVER_TELEMETRY_ENABLED="false",
                           CUA_TELEMETRY_ENABLED="false")
        self.process = subprocess.Popen(
            [str(executable), "mcp", "--direct", "--embedded", "--no-overlay"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, env=environment)
        self.messages = queue.Queue()
        self.sequence = 0
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except ValueError:
                continue
        self.messages.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", **message}) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        identifier = self.sequence
        self.send({"id": identifier, "method": method, "params": params})
        deadline = time.monotonic() + 20
        while True:
            message = self.messages.get(timeout=max(0, deadline - time.monotonic()))
            if message is None:
                raise RuntimeError("MCP process exited before replying")
            if message.get("id") == identifier:
                if "error" in message:
                    raise RuntimeError(f"MCP error code {message['error'].get('code')}")
                return message["result"]

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        structured = result.get("structuredContent", {})
        if result.get("isError") or structured.get("effect") == "refused" or structured.get("status") in ("error", "refused"):
            return None
        return structured

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def wait_for_state(path, predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            state = json.loads(path.read_text())
            if predicate(state):
                return state
        except (OSError, ValueError):
            pass
        time.sleep(.05)
    return None


def exercise_fixture(client, schemas, executable, probe_legacy):
    with tempfile.TemporaryDirectory(prefix="heymate-cua-fixture-") as directory:
        state_path = Path(directory) / "state.json"
        process = subprocess.Popen([str(executable), str(state_path)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            initial = wait_for_state(state_path, lambda state: True)
            if initial is None:
                return {"failed": "fixture did not become ready"}
            deadline = time.monotonic() + 5
            windows = []
            while time.monotonic() < deadline:
                listing = client.tool("list_windows", {"pid": process.pid, "on_screen_only": True})
                windows = [window for window in (listing or {}).get("windows", [])
                           if window.get("pid") == process.pid]
                if windows:
                    break
                time.sleep(.1)
            if len(windows) != 1:
                return {"failed": "expected exactly one fixture-owned window"}
            arguments = {"pid": process.pid, "window_id": windows[0]["window_id"],
                         "include_screenshot": False, "max_elements": 180}
            state = client.tool("get_window_state", arguments) or {}
            default_count = len(state.get("elements", []))
            if "tree_format" in schemas["get_window_state"].get("properties", {}):
                arguments["tree_format"] = "both"
            state = client.tool("get_window_state", arguments) or {}
            elements = state.get("elements", [])
            button = next((element for element in elements
                           if element.get("role") == "AXButton" and element.get("label") == "Increment counter"), None)
            field = next((element for element in elements if element.get("role") == "AXTextField"), None)
            report = {"default_structured_elements": default_count,
                      "explicit_structured_elements": len(elements), "actions": []}
            if not button or not field:
                report["failed"] = "fixture controls missing from structured snapshot"
                return report
            for expected in range(1, 4):
                started = time.perf_counter()
                result = client.tool("click", {"pid": process.pid, "element_token": button["element_token"]})
                observed = wait_for_state(state_path, lambda state: state["counter"] == expected)
                report["actions"].append({"name": "background_button_click",
                    "tool_succeeded": result is not None, "verified_in_app": observed is not None,
                    "elapsed_ms": round((time.perf_counter() - started) * 1000, 2)})
                if observed is None:
                    break
            started = time.perf_counter()
            text = "HeyMate synthetic comparison"
            result = client.tool("type_text", {"pid": process.pid,
                "element_token": field["element_token"], "text": text, "delivery_mode": "background"})
            observed = wait_for_state(state_path, lambda state: state["text"] == text)
            report["actions"].append({"name": "background_text_insertion",
                "tool_succeeded": result is not None, "verified_in_app": observed is not None,
                "elapsed_ms": round((time.perf_counter() - started) * 1000, 2)})
            if observed is not None and probe_legacy:
                started = time.perf_counter()
                selected = client.tool("hotkey", {"pid": process.pid,
                    "element_token": field["element_token"], "keys": ["cmd", "a"]})
                replaced = client.tool("type_text", {"pid": process.pid,
                    "element_token": field["element_token"], "text": "Replacement",
                    "delivery_mode": "background"}) if selected is not None else None
                observed = wait_for_state(state_path, lambda state: state["text"] == "Replacement")
                report["legacy_replacement_probe"] = {"name": "background_select_all_and_replace",
                    "tool_succeeded": selected is not None and replaced is not None,
                    "verified_in_app": observed is not None,
                    "elapsed_ms": round((time.perf_counter() - started) * 1000, 2)}
            started = time.perf_counter()
            result = client.tool("set_value", {"pid": process.pid,
                "element_token": field["element_token"], "value": "Verified native replacement"})
            observed = wait_for_state(state_path, lambda state: state["text"] == "Verified native replacement")
            confirmed = (result or {}).get("effect") == "confirmed" and any(
                evidence.get("kind") == "value_readback" for evidence in (result or {}).get("evidence", []))
            report["actions"].append({"name": "background_native_value_replacement",
                "tool_succeeded": result is not None, "driver_readback_confirmed": confirmed,
                "verified_in_app": observed is not None and confirmed,
                "elapsed_ms": round((time.perf_counter() - started) * 1000, 2)})
            final = wait_for_state(state_path, lambda state: True)
            report["frontmost_unchanged"] = final is not None and initial["frontmost_pid"] == final["frontmost_pid"]
            return report
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def inspect(executable, samples, fixture=None, probe_legacy=False):
    version = subprocess.check_output([str(executable), "--version"],
                                      text=True, timeout=10).strip()
    client = MCP(executable)
    try:
        started = time.perf_counter()
        client.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "heymate-cua-comparison", "version": "1"}})
        startup = (time.perf_counter() - started) * 1000
        client.send({"method": "notifications/initialized"})
        tools = []
        cursor = None
        while True:
            listing = client.request("tools/list", {"cursor": cursor} if cursor else {})
            tools.extend(listing["tools"])
            cursor = listing.get("nextCursor")
            if not cursor:
                break
        permission = client.tool("check_permissions", {"prompt": False})
        timings = []
        failures = 0
        for _ in range(samples):
            started = time.perf_counter()
            result = client.tool("get_screen_size", {})
            if result is None:
                failures += 1
            else:
                timings.append((time.perf_counter() - started) * 1000)
        timings.sort()
        summary = {
            "version": version, "embedded_startup_ms": round(startup, 2),
            "tool_count": len(tools),
            "permissions": {key: permission.get(key) for key in
                            ("accessibility", "screen_recording")}
            if permission is not None else {"check_failed": True},
            "permission_identity": "invoking host; not HeyMate or standalone daemon",
            "screen_size": {"successful_calls": len(timings), "failed_calls": failures,
                            "median_ms": round(timings[len(timings) // 2], 2) if timings else None,
                            "p90_ms": round(timings[math.ceil(len(timings) * .9) - 1], 2) if timings else None}}
        schemas = {tool["name"]: tool["inputSchema"] for tool in tools}
        if fixture:
            if summary["permissions"].get("accessibility") is True:
                summary["fixture"] = exercise_fixture(client, schemas, fixture, probe_legacy)
            else:
                summary["fixture"] = {"skipped": "invoking host lacks Accessibility"}
        return summary, schemas
    finally:
        client.close()


def compare(before, after, approved):
    missing = sorted(set(approved) - after.keys())
    changes = []
    breaking = []
    for name in sorted(set(approved) & before.keys() & after.keys()):
        old, new = before[name], after[name]
        if old != new:
            changes.append(name)
        added_required = set(new.get("required", [])) - set(old.get("required", []))
        removed_properties = set(old.get("properties", {})) - set(new.get("properties", {}))
        if added_required or removed_properties:
            breaking.append({"tool": name, "added_required": sorted(added_required),
                             "removed_properties": sorted(removed_properties)})
    return {"missing_approved_tools": missing, "changed_input_schemas": changes,
            "potential_breaking_changes": breaking,
            "new_tools_not_automatically_approved": sorted(after.keys() - before.keys()),
            "scope": "Tool presence and top-level schema checks; nested constraints and behavior require review."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=20, choices=range(1, 101), metavar="1..100")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path,
                        help="Optional compiled fixtures/cua-comparison.swift; clicks/types only into its own synthetic window")
    parser.add_argument("--probe-legacy-replacement", action="store_true",
                        help="Also diagnose old Cmd+A/type sequence; diagnostic failure does not count as corrected-path success")
    args = parser.parse_args()
    policy = Path(__file__).resolve().parents[1] / "Packages/HeyMateComputerUse/Sources/HeyMateComputerUse/CuaDriverToolPolicy.swift"
    source = policy.read_text()
    approved = []
    for group in ("observationTools", "actionTools"):
        body = re.search(group + r": \[String\] = \[(.*?)\n    \]", source, re.S).group(1)
        approved.extend(re.findall(r'^\s*"([a-z_]+)"', body, re.M))
    baseline, before = inspect(args.baseline, args.samples, args.fixture, args.probe_legacy_replacement)
    candidate, after = inspect(args.candidate, args.samples, args.fixture, args.probe_legacy_replacement)
    report = {"baseline": baseline, "candidate": candidate,
              "contract": compare(before, after, approved),
              "limitations": ["No capture, installer, or permission prompts; actions only in optional synthetic fixture.",
                              "No end-to-end task or HeyMate permission-continuity claim; foreground identity checked only before/after fixture actions.",
                              "Baseline runs first; timings are exploratory, not randomized benchmarks."]}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if report["contract"]["missing_approved_tools"] or report["contract"]["potential_breaking_changes"]:
        raise SystemExit(1)
    if args.fixture:
        for result in (baseline, candidate):
            fixture = result.get("fixture", {})
            if (not fixture.get("actions") or not fixture.get("frontmost_unchanged") or
                    not all(action["verified_in_app"] and action["tool_succeeded"]
                            for action in fixture["actions"])):
                raise SystemExit(1)


if __name__ == "__main__":
    main()
