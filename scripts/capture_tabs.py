#!/usr/bin/env python3
"""Capture open browser tabs for the Workspace Restorer plugin.

Usage:
  capture_tabs.py firefox <profile_dir> [profile_key]
  capture_tabs.py chromium <user_data_dir> [profile_key]

Prints a JSON object to stdout:
  {"ok": true,  "tabs": [{"url": "...", "title": "..."}, ...], "_profile": "<key OR null>"}
  {"ok": false, "error": "...",                                 "_profile": "<key OR null>"}

For Firefox it reads the sessionstore recovery file (mozLz40 + raw LZ4 block).
For Chromium it discovers an already-open DevTools debug port via the
DevToolsActivePort file and queries the CDP HTTP /json/list endpoint. It only
ever READS; it never starts a browser or opens a debug port itself.
"""

import json
import os
import shutil
import subprocess
import sys


def _decode_mozlz4(path):
    """Decode a mozLz40 raw-block LZ4 file to a JSON string."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"mozLz40\x00":
        raise ValueError("not a mozLz40 file")
    payload = data[8:]

    # Preferred: python lz4.block
    try:
        import lz4.block  # type: ignore
        return lz4.block.decompress(payload)
    except ImportError:
        pass

    # Fallback: lz4jsoncat CLI (from the lz4json package)
    lz4jsoncat = shutil.which("lz4jsoncat")
    if lz4jsoncat:
        proc = subprocess.run(
            [lz4jsoncat, path], capture_output=True, timeout=10
        )
        if proc.returncode == 0:
            return proc.stdout

    raise RuntimeError("no lz4 decoder available (install python3-lz4 or lz4json)")


def capture_firefox(profile_dir):
    candidates = [
        "sessionstore-backups/recovery.jsonlz4",
        "sessionstore-backups/recovery.baklz4",
        "sessionstore-backups/previous.jsonlz4",
    ]
    for rel in candidates:
        path = os.path.join(profile_dir, rel)
        if not os.path.isfile(path):
            continue
        try:
            raw = _decode_mozlz4(path)
            data = json.loads(raw)
        except Exception as exc:  # noqa: BLE001
            continue
        tabs = []
        for win in data.get("windows", []):
            for tab in win.get("tabs", []):
                entries = tab.get("entries", [])
                idx = tab.get("index", 1) - 1
                entry = entries[idx] if 0 <= idx < len(entries) else None
                if entry and entry.get("url"):
                    tabs.append({"url": entry["url"], "title": entry.get("title", "")})
        return {"ok": True, "tabs": tabs}
    return {"ok": False, "error": "no firefox session backup found"}


def capture_chromium(user_data_dir):
    active_port = os.path.join(user_data_dir, "DevToolsActivePort")
    if not os.path.isfile(active_port):
        return {"ok": False, "error": "no DevToolsActivePort (browser not started with --remote-debugging-port)"}
    try:
        with open(active_port, "r", encoding="utf-8") as f:
            lines = [l.strip() for l in f.readlines() if l.strip()]
        if not lines:
            return {"ok": False, "error": "empty DevToolsActivePort"}
        port = lines[0]
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": "could not read DevToolsActivePort: %s" % exc}

    try:
        proc = subprocess.run(
            ["curl", "-s", "--max-time", "3", "http://127.0.0.1:%s/json/list" % port],
            capture_output=True, timeout=5, text=True,
        )
        targets = json.loads(proc.stdout)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": "CDP query failed: %s" % exc}

    tabs = []
    for t in targets:
        if isinstance(t, dict) and t.get("type") == "page" and t.get("url"):
            tabs.append({"url": t["url"], "title": t.get("title", "")})
    return {"ok": True, "tabs": tabs}


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "usage: capture_tabs.py <firefox|chromium> <path> [key]"}))
        return 1
    kind, path = sys.argv[1], sys.argv[2]
    key = sys.argv[3] if len(sys.argv) > 3 else None
    if kind == "firefox":
        result = capture_firefox(path)
    elif kind == "chromium":
        result = capture_chromium(path)
    else:
        result = {"ok": False, "error": "unknown browser type: %s" % kind}
    result["_profile"] = key
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
