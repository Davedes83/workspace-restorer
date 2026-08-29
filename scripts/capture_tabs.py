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


# Schemes a tab URL may use and still be worth restoring. Mirrors the
# safeUrl() allowlist used on the restore side (restoreLogic.mjs), so tabs
# that aren't plain http/https (e.g. locally-opened files) are not silently
# dropped during capture.
_CAPTURE_URL_SCHEMES = (
    "http:",
    "https:",
    "file:",
    "chrome:",
    "edge:",
    "brave:",
    "moz-extension:",
    "view-source:",
    "about:",
    "chrome-extension:",
)


def _scheme(url):
    if ":" in url:
        return url.split(":", 1)[0] + ":"
    return ""


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


def _firefox_base_dirs(hint):
    """Return a list of candidate Firefox base directories to inspect.

    Firefox may keep its profiles under ``~/.mozilla/firefox`` (traditional)
    or ``$XDG_CONFIG_HOME/mozilla/firefox`` (e.g. ``~/.config/mozilla/firefox``,
    used by many distributions/installs). ``hint`` is whatever path the
    window's command line suggested. We return that plus the standard locations
    (deduplicated, in priority order), so capture finds the active profile
    regardless of which install layout / hint we were handed.
    """
    home = os.path.expanduser("~")
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    bases = [
        os.path.expanduser(hint),
        os.path.join(home, ".mozilla", "firefox"),
        os.path.join(xdg, "mozilla", "firefox"),
    ]
    return list(dict.fromkeys(b for b in bases if b))


def _find_active_firefox_profile(profile_dir):
    """Resolve the concrete Firefox profile directory to inspect.

    ``profile_dir`` may be a specific profile directory (has sessionstore /
    prefs.js), a Firefox base directory (has profiles.ini), or a stale hint.
    We always search the candidate base dirs for the profile whose
    ``sessionstore-backups/recovery.jsonlz4`` is newest — that is the profile
    Firefox is actually running from — so this is robust to profiles.ini
    format differences (section-level ``Default=1`` vs ``[Install...]``
    Default=) and to XDG vs traditional base locations.
    """
    # Fast path: we were already given a real, active profile directory.
    for base in _firefox_base_dirs(profile_dir):
        probe = base
        if (os.path.isfile(os.path.join(probe, "prefs.js"))
                or os.path.isfile(os.path.join(probe, "sessionstore-backups", "recovery.jsonlz4"))):
            return probe, True

    best = None
    best_mtime = -1
    for base in _firefox_base_dirs(profile_dir):
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            prof = os.path.join(base, name)
            sess = os.path.join(prof, "sessionstore-backups", "recovery.jsonlz4")
            if not os.path.isfile(sess):
                continue
            try:
                mt = os.path.getmtime(sess)
            except OSError:
                continue
            if mt > best_mtime:
                best, best_mtime = prof, mt
    if best:
        return best, False
    return profile_dir, False


def _firefox_tabs_from_session(data):
    tabs = []
    seen = set()
    for win in data.get("windows", []):
        for tab in win.get("tabs", []):
            entries = tab.get("entries", [])
            idx = tab.get("index", 1) - 1
            entry = entries[idx] if 0 <= idx < len(entries) else None
            if entry and entry.get("url") and entry["url"] not in seen:
                seen.add(entry["url"])
                tabs.append({"url": entry["url"], "title": entry.get("title", "")})
    return tabs


def _read_firefox_tabs(profile_dir):
    # Firefox flushes `recovery.jsonlz4` on a short timer, not on every tab
    # change, so an immediate snapshot can see a stale/sparse file that lags
    # the live tabs. Decode every decodable session-store variant and keep the
    # one with the most tabs as the most complete view of the added/commented
    # ones, so capture is not stuck on whichever file was flushed most recently.
    best = None
    for rel in ("recovery.jsonlz4", "recovery.baklz4", "previous.jsonlz4"):
        path = os.path.join(profile_dir, "sessionstore-backups", rel)
        if not os.path.isfile(path):
            continue
        try:
            raw = _decode_mozlz4(path)
            tabs = _firefox_tabs_from_session(json.loads(raw))
        except Exception as exc:  # noqa: BLE001
            continue
        if not tabs:
            continue
        if best is None or len(tabs) > len(best):
            best = tabs
    if best is None:
        return None
    return {"ok": True, "tabs": best}


def capture_firefox(profile_dir):
    resolved, _ = _find_active_firefox_profile(profile_dir)
    result = _read_firefox_tabs(resolved)
    if result is not None:
        return result
    # The profile dir may not be the active one; fall back to checking each
    # candidate base dir's profiles for a readable session backup.
    for base in _firefox_base_dirs(profile_dir):
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            prof = os.path.join(base, name)
            if not os.path.isdir(prof):
                continue
            result = _read_firefox_tabs(prof)
            if result is not None:
                return result
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
                    if _scheme(url) in _CAPTURE_URL_SCHEMES:
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
