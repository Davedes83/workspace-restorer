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
import struct
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
    # Primary: an already-open DevTools debug port (browser launched with
    # --remote-debugging-port). Only reads; never starts a browser.
    tabs = _capture_chromium_cdp(user_data_dir)
    if tabs is not None and tabs:
        return {"ok": True, "tabs": tabs}
    # Fallback: decode Vivaldi/Chromium "Sessions/Tabs_*" SNSS session files
    # for the current open tabs. Works for normal browser launches that were
    # not started with a debug port.
    tabs = _capture_vivaldi_snss(user_data_dir)
    if tabs is not None and tabs:
        return {"ok": True, "tabs": tabs}
    if tabs is None:
        return {"ok": False, "error": "no DevToolsActivePort (browser not started with --remote-debugging-port)"}
    return {"ok": False, "error": "no current tabs found in sessions files"}


def _capture_chromium_cdp(user_data_dir):
    active_port = os.path.join(user_data_dir, "DevToolsActivePort")
    if not os.path.isfile(active_port):
        return None
    try:
        with open(active_port, "r", encoding="utf-8") as f:
            lines = [l.strip() for l in f.readlines() if l.strip()]
        if not lines:
            return None
        port = lines[0]
    except Exception:  # noqa: BLE001
        return None

    try:
        proc = subprocess.run(
            ["curl", "-s", "--max-time", "3", "http://127.0.0.1:%s/json/list" % port],
            capture_output=True, timeout=5, text=True,
        )
        targets = json.loads(proc.stdout)
    except Exception:  # noqa: BLE001
        return None

    tabs = []
    for t in targets:
        if isinstance(t, dict) and t.get("type") == "page" and t.get("url"):
            tabs.append({"url": t["url"], "title": t.get("title", "")})
    return tabs


def _iter_snss_records(path):
    """Yield (command_id, contents) records from a Vivaldi/Chromium SNSS file."""
    d = open(path, "rb").read()
    if d[:4] != b"SNSS" or len(d) < 8:
        return
    off = 8
    while off + 2 <= len(d):
        size = struct.unpack_from("<H", d, off)[0]
        off += 2
        if off + size > len(d):
            break
        cid = d[off]
        yield cid, d[off + 1 : off + size]
        off += size


def _capture_vivaldi_snss(user_data_dir):
    """Decode Chromium-family 'Sessions/Session_*' SNSS files.

    Format (Session Service dialect, validated against a live Vivaldi 8.1
    session):
      * File header: b'SNSS' + int32 version (3); then length-prefixed records.
      * Each record: uint16 LE byte_len, uint8 command_id, then payload.
      * Session Service commands:
          0  SetTabWindow                {window_id, tab_id}
          2  SetTabIndexInWindow         {tab_id, index}
          6  UpdateTabNavigation (Pickle) [u32 pickle_size][i32 tab_id]
             [i32 index][u32 url_len][url utf-8][string16 title]...
          7  SetSelectedNavigationIndex  {tab_id, index}
          8  SetSelectedTabInIndex       {window_id, index}
    The currently-open URL for a tab is its navigation entry at the tab's
    selected navigation index (command 7; defaults to last entry).

    NOTE: the older `Tabs_*` files are the "recently closed tabs" restore
    list (a different dialect and not the live session), so we read the
    `Session_*` files instead.
    """
    candidates = []
    for base in (user_data_dir, os.path.join(user_data_dir, "Default")):
        sess = os.path.join(base, "Sessions")
        if os.path.isdir(sess):
            for name in os.listdir(sess):
                if name.startswith("Session_"):
                    candidates.append(os.path.join(sess, name))
    if not candidates:
        return None
    # The active session is the most recently written Session_* file.
    path = max(candidates, key=os.path.getmtime)

    nav = {}   # tab_id -> {index: url}
    tabwin = {}  # tab_id -> window_id
    tabidx = {}  # tab_id -> index within window
    selecnav = {}   # tab_id -> selected navigation index
    selidx = {}     # window_id -> selected tab index
    try:
        for cid, contents in _iter_snss_records(path):
            if cid == 6 and len(contents) >= 16:
                # UpdateTabNavigation: [u32 pickle][i32 tab_id][i32 index]
                #   [u32 url_len][url]...
                tid, idx, ulen = struct.unpack_from("<iiI", contents, 4)
                if 0 < ulen <= 4096 and 16 + ulen <= len(contents):
                    url = contents[16 : 16 + ulen].decode("utf-8", "replace")
                    if url.startswith(("http://", "https://")):
                        nav.setdefault(tid, {})[idx] = url
            elif cid == 0 and len(contents) >= 8:
                wid, tid = struct.unpack_from("<ii", contents, 0)
                tabwin[tid] = wid
            elif cid == 2 and len(contents) >= 8:
                tid, idx = struct.unpack_from("<ii", contents, 0)
                tabidx[tid] = idx
            elif cid == 7 and len(contents) >= 8:
                tid, idx = struct.unpack_from("<ii", contents, 0)
                selecnav[tid] = idx
            elif cid == 8 and len(contents) >= 8:
                wid, idx = struct.unpack_from("<ii", contents, 0)
                selidx[wid] = idx
    except Exception:  # noqa: BLE001
        return None

    wins = {}
    for tid, wid in tabwin.items():
        wins.setdefault(wid, []).append(tid)

    seen = set()
    tabs = []
    for wid in wins:
        ordered = sorted(wins[wid], key=lambda t: tabidx.get(t, 0))
        for tid in ordered:
            hist = nav.get(tid, {})
            if not hist:
                continue
            sel = selecnav.get(tid)
            url = hist.get(sel) if sel is not None else None
            if url is None:
                url = hist[max(hist)]
            if url and url not in seen:
                seen.add(url)
                tabs.append({"url": url, "title": ""})
    return tabs


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
