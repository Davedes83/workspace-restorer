#!/usr/bin/env python3
"""Resolve a window class to a launch command from the TRUSTED desktop database.

Why this exists
---------------
Restoring a window needs to know how to start the app again. The obvious
source - the captured `/proc/<pid>/cmdline` - is controlled by the application
itself: any process may rewrite its own argv at will. Restoring that string
means a sandboxed app can hand the restorer an interpreter invocation
(`sh -c ...`, `env ...`, `python3 -c ...`) and have it executed on the host,
outside the sandbox it was confined to. Shell quoting does not help, because
the whole command is the untrusted value rather than an argument inside a
trusted one.

So this helper never looks at the snapshot. It reads only the freedesktop
application database - directories owned by root or by the user, never by a
sandboxed application - and reports the `Exec` tokens registered for a window
class. All validation is done on the QML/JS side (restoreLogic.js), which is
where the unit tests live; this script only collects candidate tokens.

Output is a single JSON object on stdout:

    {"wmclass:firefox": ["/usr/lib/firefox/firefox"],
     "name:firefox":   ["/usr/lib/firefox/firefox"]}

Nothing is executed, no temporary file is written, and no network or
subprocess is used.
"""

import json
import os
import re
import sys

# Directories searched for .desktop files, in XDG precedence order. Later
# entries win, matching how the desktop resolves an application id.
#
# These are all host-side locations. A Flatpak/Snap application confined by its
# sandbox cannot write to /usr/share/applications and has no business writing
# to the host ~/.local/share/applications either, so an installed entry cannot
# be planted by the very apps whose argv we are refusing to trust.
DESKTOP_DIRS = (
    "/usr/local/share/applications",
    "/usr/share/applications",
    "/var/lib/flatpak/exports/share/applications",
)

# Bounds. The database is a few thousand small files; these caps keep a
# pathological or attacker-inflated directory from stalling the shell at start.
MAX_FILES = 4096
MAX_FILE_BYTES = 256 * 1024
MAX_ENTRIES = 8192

# Field codes carry no launch semantics for us - %u/%U would append URLs,
# %f/%F a file. They are stripped rather than passed through.
_FIELD_CODE_RE = re.compile(r"%%|%[fFuUickdDNvVm]")

# Only `Type=Application` entries describe something we can run.
_TYPE_APP_RE = re.compile(r"^Type\s*=\s*(\S+)", re.M)
_EXEC_RE = re.compile(r"^Exec\s*=\s*(.*)$", re.M)
_WMCLASS_RE = re.compile(r"^StartupWMClass\s*=\s*(\S+)", re.M)


def _desktop_dirs():
    """XDG-ordered desktop directories that exist, including the user's."""
    dirs = list(DESKTOP_DIRS)
    home = os.path.expanduser("~")
    dirs.append(os.path.join(home, ".local", "share", "applications"))
    flatpak_home = os.path.join(
        home, ".local", "share", "flatpak", "exports", "share", "applications"
    )
    dirs.append(flatpak_home)

    seen = set()
    out = []
    for d in dirs:
        real = os.path.realpath(d)
        if real in seen:
            continue
        seen.add(real)
        if os.path.isdir(real):
            out.append(real)
    return out


def _parse_entry(path):
    """Return (exec_line, wmclass) for one .desktop file, or None to skip."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            blob = fh.read(MAX_FILE_BYTES)
    except (OSError, ValueError):
        return None

    # `Hidden`/`NoDisplay` entries are filtered out upstream by the desktop
    # environment; they are not things the user launched from a menu.
    if re.search(r"^Hidden\s*=\s*true", blob, re.M):
        return None

    type_match = _TYPE_APP_RE.search(blob)
    if not type_match or type_match.group(1).lower() != "application":
        return None

    exec_match = _EXEC_RE.search(blob)
    if not exec_match:
        return None

    wm_match = _WMCLASS_RE.search(blob)
    return exec_match.group(1).strip(), (wm_match.group(1) if wm_match else None)


def _strip_field_codes(exec_line):
    # %F/%U may expand to several arguments, so replace with a space rather
    # than deleting, to avoid gluing neighbouring tokens together.
    return _FIELD_CODE_RE.sub(" ", exec_line).strip()


def build_index(dirs=None):
    """Map index keys to raw Exec token lists.

    Keys are prefixed by kind so a StartupWMClass can never shadow a name:
        "wmclass:<lowercased StartupWMClass>"
        "name:<lowercased desktop file basename>"
    """
    index = {}
    files_seen = 0
    for directory in (dirs if dirs is not None else _desktop_dirs()):
        try:
            entries = sorted(os.listdir(directory))
        except OSError:
            continue
        for entry in entries:
            if not entry.endswith(".desktop"):
                continue
            files_seen += 1
            if files_seen > MAX_FILES or len(index) > MAX_ENTRIES:
                return index
            path = os.path.join(directory, entry)
            if not os.path.isfile(path):
                continue
            parsed = _parse_entry(path)
            if parsed is None:
                continue
            exec_line, wmclass = parsed
            exec_line = _strip_field_codes(exec_line)
            if not exec_line:
                continue
            # Tokens are returned as a single-element list: tokenizing
            # correctly (quotes, escapes) is the consumer's job and belongs in
            # the tested JS. Keeping the raw line here means one tokenizer.
            name_key = "name:" + entry[: -len(".desktop")].lower()
            index[name_key] = [exec_line]
            # Skip KDE's "@@startup_wm_class" placeholder, which marks an
            # entry whose real WM class is only known after launch.
            if wmclass and "@@" not in wmclass:
                wm_key = "wmclass:" + wmclass.lower()
                if wm_key not in index:
                    index[wm_key] = [exec_line]
    return index


def main():
    try:
        index = build_index()
    except Exception as exc:  # never take the shell down over a bad entry
        sys.stderr.write("desktop_launch: %s\n" % exc)
        index = {}
    sys.stdout.write(json.dumps(index))
    return 0


if __name__ == "__main__":
    sys.exit(main())