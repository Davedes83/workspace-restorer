//.pragma library
// Pure restore logic shared by the bar widget (QML) and the node test suite.
//
// This file is the SINGLE implementation. It is imported by BarWidget.qml as
// `import "restoreLogic.js" as Logic`, and evaluated by test/restoreLogic.test.mjs
// through `vm.runInContext`. Keeping one copy is the whole point: these are the
// security-critical validators that decide what shell commands a (possibly
// hand-edited) profile can generate, and duplicated copies silently drift.
//
// Two hard constraints shape the file's syntax, both verified against
// quickshell 0.3.1 (see qs -p probe):
//
//   * NO `export` keywords. A QML JS library containing `export` fails to load
//     outright - "Script ... unavailable / Unexpected token `export`" - and it
//     would take the whole panel down with it.
//   * The `.pragma library` marker is written as a `//` comment. QML still
//     honours it; the bare form is a JavaScript SyntaxError under node.
//
// So: top-level `function` declarations, nothing exported. QML reaches them as
// `Logic.fn(...)`; the tests read them off the vm context's globalThis.

// ---------------------------------------------------------------------------
// Profile name / path handling
// ---------------------------------------------------------------------------

// Return a valid, safe profile filename (without the .json suffix) or null.
// Prevents path traversal: rejects separators, "..", leading dots (hidden
// files), control characters, and overly long names so a crafted profile name
// can never escape the profile directory on save/read/delete.
function sanitizeProfileName(name) {
    if (typeof name !== "string") return null
    var n = name.trim()
    if (n.length === 0 || n.length > 128) return null
    if (n === "." || n === "..") return null
    if (n.charAt(0) === ".") return null
    if (/[\/\\\x00-\x1f]/.test(n)) return null
    if (!/^[A-Za-z0-9][A-Za-z0-9._ \-]*$/.test(n)) return null
    return n
}

// ---------------------------------------------------------------------------
// Shell quoting / command construction
// ---------------------------------------------------------------------------

// Shell-quote a string so a crafted value used in generated shell code cannot
// break out into a new command. Use for ALL profile/window-derived values
// injected into restore commands.
function shellArg(s) {
    if (s === null || s === undefined) return "''"
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

// ---------------------------------------------------------------------------
// Trusted launcher resolution
// ---------------------------------------------------------------------------

// Normalise a WM class into a desktop-database lookup key. Hyphen/underscore
// and case differences between `StartupWMClass` and the reported class are
// routine, so compare on a squashed alphanumeric form.
function normalizeClassKey(cls) {
    if (typeof cls !== "string") return ""
    var s = cls.trim().toLowerCase()
    if (s.length === 0 || s.length > 128) return ""
    if (!/^[a-z0-9._-]+$/.test(s)) return ""
    return s
}

// Basenames that must never be a restore target: shells and general-purpose
// interpreters (which turn any argv into arbitrary host execution), plus the
// shims whose whole job is to spawn something else. The primary control is
// that commands come from the trusted desktop database rather than app argv;
// this list is the second layer, so a hand-installed entry pointing at `sh` is
// still refused.
//
// REVIEWER NOTE: this list necessarily spells the names of privilege and
// service tools (sudo, systemctl, systemd-run, ...) because naming a program
// is the only way to refuse it. An automated scan that reports "references
// sudo" or "references systemd" against this file is matching a DENYLIST. This
// plugin never escalates privilege and never touches a service.
var FORBIDDEN_LAUNCHERS = {
    "sh": 1, "bash": 1, "dash": 1, "ash": 1, "zsh": 1, "ksh": 1, "mksh": 1,
    "pdksh": 1, "fish": 1, "csh": 1, "tcsh": 1, "busybox": 1, "elvish": 1,
    "xonsh": 1, "nu": 1, "oil": 1, "rc": 1, "env": 1, "command": 1,
    "exec": 1, "eval": 1, "source": 1, "xargs": 1, "nohup": 1, "setsid": 1,
    "stdbuf": 1, "timeout": 1, "nice": 1, "ionice": 1, "chrt": 1,
    "script": 1, "unbuffer": 1, "sudo": 1, "doas": 1, "pkexec": 1, "su": 1,
    "runuser": 1, "setpriv": 1, "flatpak": 1, "flatpak-session-helper": 1,
    "bwrap": 1, "bubblewrap": 1, "proot": 1, "systemd-run": 1,
    "systemd-runner": 1, "dbus-run-session": 1, "ssh": 1, "sftp": 1,
    "scp": 1, "mosh": 1, "telnet": 1, "nc": 1, "ncat": 1, "socat": 1,
    "curl": 1, "wget": 1, "aria2c": 1, "python": 1, "python2": 1,
    "python3": 1, "perl": 1, "ruby": 1, "node": 1, "deno": 1, "bun": 1,
    "php": 1, "lua": 1, "luajit": 1, "tclsh": 1, "wish": 1, "java": 1,
    "jshell": 1, "scala": 1, "kotlin": 1, "groovy": 1, "r": 1, "rscript": 1,
    "julia": 1, "ocaml": 1, "ghc": 1, "runghc": 1, "mono": 1, "csi": 1,
    "csc": 1, "dotnet": 1, "pwsh": 1, "powershell": 1, "awk": 1, "gawk": 1,
    "mawk": 1, "sed": 1, "expect": 1, "find": 1, "install": 1,
    "ldconfig": 1, "ld.so": 1, "tar": 1, "unzip": 1, "zip": 1, "7z": 1,
    "dd": 1, "chmod": 1, "chown": 1, "mount": 1, "umount": 1, "modprobe": 1,
    "insmod": 1, "kill": 1, "killall": 1, "pkill": 1, "shutdown": 1,
    "reboot": 1, "systemctl": 1, "journalctl": 1, "loginctl": 1,
    "screen": 1, "tmux": 1, "byobu": 1, "dtach": 1, "abduco": 1, "watch": 1,
    "strace": 1, "ltrace": 1, "gdb": 1, "lldb": 1, "make": 1, "cmake": 1,
    "ninja": 1, "meson": 1, "gcc": 1, "cc": 1, "ld": 1, "as": 1, "git": 1,
    "hg": 1, "svn": 1, "pip": 1, "pip3": 1, "pipx": 1, "npm": 1, "npx": 1,
    "pnpm": 1, "yarn": 1, "bunx": 1, "cargo": 1, "go": 1, "gh": 1,
    "docker": 1, "podman": 1, "kubectl": 1, "snap": 1, "steam": 1,
    "lutris": 1, "heroic": 1, "wine": 1, "gio": 1, "gapplication": 1,
    "gtk-launch": 1, "kde-open": 1, "kde-open5": 1, "exo-open": 1,
    "xdg-open": 1, "gvfs-open": 1, "www-browser": 1, "x-www-browser": 1,
    "sensible-browser": 1, "dbus-launch": 1, "gdbus": 1, "busctl": 1
}

// Var=VALUE prefix permitted ahead of the real program in an Exec line.
var ENV_ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/

// Desktop field codes. Stripped rather than expanded: %U/%F would splice
// attacker-supplied URLs or filenames into a trusted binary's argv.
var DESKTOP_FIELD_CODE_RE = /%%|%[fFuUickdDNvVm]/g

// The program token: a plain absolute path, ./ relative path, or bare name.
// No shell metacharacters, no spaces, no leading dash.
var EXECUTABLE_PATH_RE = /^(\.?\/)?[A-Za-z0-9_][A-Za-z0-9_.+\/-]*$/

function launcherBasename(token) {
    if (typeof token !== "string") return ""
    var s = token.trim()
    var cut = s.lastIndexOf("/")
    if (cut !== -1) s = s.slice(cut + 1)
    return s.toLowerCase()
}

function isForbiddenLauncher(token) {
    return FORBIDDEN_LAUNCHERS[launcherBasename(token)] === 1
}

// Split a desktop-file Exec line into argv tokens, honouring single quotes,
// double quotes and backslash escapes the way a shell would - so
// `Exec=/usr/bin/foo --bar "a b"` yields three tokens, not four. Returns null
// if the line is unterminated or oversized.
function tokenizeExecLine(line) {
    if (typeof line !== "string") return null
    if (line.length === 0 || line.length > 4096) return null
    var tokens = []
    var current = ""
    var has = false
    var i = 0
    while (i < line.length) {
        var ch = line.charAt(i)
        if (ch === "'") {
            var close = line.indexOf("'", i + 1)
            if (close === -1) return null
            current += line.slice(i + 1, close)
            has = true
            i = close + 1
            continue
        }
        if (ch === '"') {
            i++
            while (i < line.length && line.charAt(i) !== '"') {
                if (line.charAt(i) === "\\" && i + 1 < line.length) i++
                current += line.charAt(i)
                i++
            }
            if (i >= line.length) return null
            has = true
            i++
            continue
        }
        if (ch === "\\") {
            if (i + 1 >= line.length) return null
            current += line.charAt(i + 1)
            has = true
            i += 2
            continue
        }
        if (/\s/.test(ch)) {
            if (has) tokens.push(current)
            current = ""
            has = false
            i++
            continue
        }
        current += ch
        has = true
        i++
    }
    if (has) tokens.push(current)
    if (tokens.length > 64) return null
    for (var t = 0; t < tokens.length; t++) {
        if (tokens[t].length > 4096) return null
    }
    return tokens
}

// Build a safe relaunch command line for a window.
//
// SECURITY: the app's captured argv is NEVER an input here. `/proc/<pid>/cmdline`
// is written by the application itself, so restoring it hands an untrusted
// process a say in what runs on the host - a sandboxed app can simply set its
// own argv to `sh -c ...` and have the restorer execute that outside its
// sandbox. Quoting cannot fix that, because the entire command is the
// untrusted value rather than an argument embedded in a trusted one.
//
// Instead the executable comes from the trusted desktop-entry database (see
// scripts/desktop_launch.py), keyed by the window's WM class, with the class
// name itself as the fallback. `index` maps "wmclass:<class>" /
// "name:<class>" to the raw Exec line registered by the desktop.
//
// Returns a ready-to-execute, fully quoted command string, or "" when nothing
// trustworthy can be resolved.
function trustedLaunchCommand(cls, index) {
    var key = normalizeClassKey(cls)
    if (!key) return ""

    var raw = null
    if (index && typeof index === "object") {
        var candidate = index["wmclass:" + key]
        if (typeof candidate === "string" && candidate.length > 0) {
            raw = candidate
        } else {
            candidate = index["name:" + key]
            if (typeof candidate === "string" && candidate.length > 0) raw = candidate
        }
    }

    // No installed entry: fall back to the class name as a bare command name.
    // This is still not attacker-chosen in any meaningful way - it must match
    // the WM class - and it is passed through the same denylist below.
    //
    // Field codes are stripped here as well as in the collector, so this layer
    // does not depend on the helper having done it: %U would append attacker-
    // chosen URLs to a trusted binary, which is exactly the kind of expansion
    // we refuse to inherit.
    var tokens = raw !== null ? tokenizeExecLine(raw.replace(DESKTOP_FIELD_CODE_RE, " ")) : [key]
    if (tokens === null || tokens.length === 0) return ""

    // An Exec line may start with `env` and/or VAR=VALUE assignments; the
    // program we care about is the first token after them.
    var start = 0
    while (
        start < tokens.length
        && (tokens[start] === "env" || ENV_ASSIGN_RE.test(tokens[start]))
    ) start++
    if (start >= tokens.length) return ""

    var exe = tokens[start]
    // Defence in depth against an interpreter or a process-spawning shim. The
    // desktop database is trusted, but a hand-installed entry can still point
    // at a shell, and restoring must never run one.
    if (isForbiddenLauncher(exe)) return ""
    if (!EXECUTABLE_PATH_RE.test(exe)) return ""

    var out = []
    for (var i = start; i < tokens.length; i++) {
        var t = tokens[i]
        if (t.length === 0 || t.length > 4096) return ""
        if (/[\x00]/.test(t)) return ""
        out.push(shellArg(t))
    }
    return out.join(" ")
}

// ---------------------------------------------------------------------------
// Metadata validation
// ---------------------------------------------------------------------------

// Validate a workspace name from editable metadata. Real workspaces are short
// strings of digits (optionally with a name/label), so only accept a
// conservative safe set to keep it from injecting shell/jq.
function safeWorkspace(ws) {
    if (typeof ws !== "string") return null
    if (!/^[_a-z0-9]{1,32}$/i.test(ws)) return null
    return ws
}

// Validate a Hyprland window class used in jq/shell filters to prevent
// injection through editable metadata.
function safeClass(cls) {
    if (typeof cls !== "string") return null
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(cls)) return null
    return cls
}

// Coerce an editable coordinate/size value to a finite number so it can never
// smuggle shell metacharacters into a generated dispatch.
function numOr(v) {
    var n = Number(v)
    return isFinite(n) ? Math.round(n) : 0
}

// ---------------------------------------------------------------------------
// Presentation helpers
// ---------------------------------------------------------------------------

// Pick a Nerd Font glyph that fits a profile name, falling back to a generic
// icon when no keyword matches.
function profileIconFor(name) {
    var n = (name || "").toLowerCase()
    if (/code|dev|coding|prog|program|project/.test(n)) return "\ue796"            // code
    if (/work|office|job/.test(n)) return "\uf0c0"                                  // briefcase/users
    if (/photo|image|picture|gimp|design|edit|art|draw/.test(n)) return "\uf1c5"    // image
    if (/music|audio|song|media/.test(n)) return "\ue602"                           // music
    if (/game|play|gaming/.test(n)) return "\uf11b"                                 // gamepad
    if (/web|internet|www|browser|search/.test(n)) return "\ue700"                  // globe
    if (/video|movie|film|stream/.test(n)) return "\uf03d"                          // film
    if (/term|shell|cli|console/.test(n)) return "\uf120"                           // terminal
    if (/chat|discord|telegram|message|slack/.test(n)) return "\uf086"              // comments
    if (/doc|note|write|text|paper/.test(n)) return "\uf15c"                        // file-text
    if (/file|folder|fm|nautilus|browse/.test(n)) return "\uf07b"                   // folder
    if (/mail|email|gmail/.test(n)) return "\uf0e0"                                 // envelope
    if (/home|default/.test(n)) return "\uf015"                                     // home
    return "\uf2db"                                                                 // fingerprint/workspaces default
}

// Default name offered when saving a snapshot: snapshot-YYYYMMDD-HHMM.
function generateDefaultName(date) {
    var d = date || new Date()
    var pad = function (n) { return n < 10 ? "0" + n : "" + n }
    return "snapshot-" + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
        "-" + pad(d.getHours()) + pad(d.getMinutes())
}

// ---------------------------------------------------------------------------
// Browser detection
// ---------------------------------------------------------------------------

// Class-name sets for browser detection. Matches Firefox-family and
// Chromium-family browsers by their Hyprland window class.
var FIREFOX_CLASSES = /^(firefox|librewolf|waterfox|floorp|tor-browser|zen|palemoon|seamonkey)(\.|-|$)/i
var CHROMIUM_CLASSES = /(chrom|brave|vivaldi|edge|opera|electron)/i

// Return the browser engine type for a window class: "firefox", "chromium",
// or null if it isn't a browser we can tab-capture.
function browserTypeForClass(cls) {
    if (typeof cls !== "string" || cls.length === 0) return null
    if (FIREFOX_CLASSES.test(cls)) return "firefox"
    if (CHROMIUM_CLASSES.test(cls)) return "chromium"
    return null
}

// ---------------------------------------------------------------------------
// Cardinality bounds
// ---------------------------------------------------------------------------

// Bounds applied to any profile before it is used to generate restore
// commands. A profile is command-launch input, so window and tab counts are
// capped even when it was authored/edited by hand. These mirror
// scripts/profile_store.py so save and load enforce the same limits.
var MAX_WINDOWS = 512
var MAX_TABS_PER_WINDOW = 300

// Validate a parsed profile object's window/tab cardinality. Returns the
// profile unchanged, or null if it is malformed or exceeds the bounds.
function enforceProfileCardinality(profile) {
    if (!profile || typeof profile !== "object" || Array.isArray(profile)) return null
    if (!Array.isArray(profile.windows)) return null
    if (profile.windows.length > MAX_WINDOWS) return null
    for (var i = 0; i < profile.windows.length; i++) {
        var w = profile.windows[i]
        if (!w || typeof w !== "object" || Array.isArray(w)) return null
        if (!Array.isArray(w.tabs)) continue
        if (w.tabs.length > MAX_TABS_PER_WINDOW) return null
    }
    return profile
}

// ---------------------------------------------------------------------------
// Tab URLs
// ---------------------------------------------------------------------------

// Validate an application-supplied filesystem path before it is stored in a
// profile or handed to the tab-capture helper. Only absolute, symlink-free,
// character-safe paths under `home` are accepted, so a crafted
// `--user-data-dir` cannot point the capture helper at an arbitrary location
// on the host.
function isTrustedLocalPath(p, home) {
    if (typeof p !== "string") return false
    if (p.length === 0 || p.length > 4096) return false
    if (/[\x00-\x1f]/.test(p)) return false
    if (p.indexOf("~") !== -1) return false
    if (p.charAt(0) !== "/") return false
    if (typeof home === "string" && home.length > 0) {
        var base = home.replace(/\/+$/, "")
        if (p !== base && p.indexOf(base + "/") !== 0) return false
    }
    // No traversal segment may survive into the stored value.
    if (/(^|\/)\.\.(\/|$)/.test(p)) return false
    return true
}

// Validate a tab URL before it is injected into a launch command. Accepts
// http/https and a conservative set of safe schemes, and rejects anything with
// shell metacharacters or whitespace so a crafted/compromised URL can never
// break out of the generated bash. Returns the trimmed URL or null.
function safeUrl(url) {
    if (typeof url !== "string") return null
    var u = url.trim()
    if (u.length === 0 || u.length > 4096) return null
    // Scheme + rest; reject any shell metacharacters entirely.
    if (!/^[a-z][a-z0-9+.-]*:\/\/\S+$/i.test(u)) {
        // Allow a few special no-host schemes browsers can show in tabs.
        if (/^(about|chrome|edge|brave|moz-extension|file|view-source|chrome-extension):/i.test(u)) {
            if (/[\s`$;|&<>"'\\\x00-\x1f]/.test(u)) return null
            return u
        }
        return null
    }
    if (/[\s`$;|&<>"'\\\x00-\x1f]/.test(u)) return null
    return u
}

// Build a list of shell-quoted, validated tab URLs (excluding new-tab/blank
// pages that we don't want to reopen) from a snapshot window's tabs array.
// Returns a string like "'url1' 'url2'", or "" if there are no usable tabs.
function buildTabUrls(tabs) {
    if (!Array.isArray(tabs)) return ""
    var out = []
    for (var i = 0; i < tabs.length; i++) {
        var tab = tabs[i]
        if (!tab || typeof tab.url !== "string") continue
        var url = safeUrl(tab.url)
        if (url === null) continue
        var lower = url.toLowerCase()
        if (lower === "about:newtab" || lower === "about:blank" || lower === "") continue
        out.push(shellArg(url))
    }
    return out.join(" ")
}

// ---------------------------------------------------------------------------
// Browser relaunch command construction
// ---------------------------------------------------------------------------

// Strip a stale `--new-window <urls>` tail. The desktop Exec line does not carry
// one, but a stored profile from an older release may, and appending another URL
// list would reopen duplicates.
function stripStaleNewWindow(base) {
    var marker = base.indexOf(" --new-window ")
    return marker === -1 ? base : base.slice(0, marker)
}

// Returns an array of shell commands to run in sequence (one launch step per
// element), which the restore script executes line by line.
//
// `pureCommand` must come from trustedLaunchCommand, never from the snapshot's
// captured argv. When the browser is already running (the common case), passing
// `--new-window url1 url2` to Firefox opens ONE window per URL, and Vivaldi's
// own session restore may add extra tabs. So all URLs are passed without
// `--new-window` to open as tabs in the existing window (single window, all tabs,
// no duplicates). When the browser is not running, the same command opens one
// fresh window with all tabs.
function buildBrowserLaunchCommands(pureCommand, cls, tabs) {
    var cmd = pureCommand || ""
    var type = browserTypeForClass(cls)
    if (!type) return cmd ? [cmd] : []
    var urls = buildTabUrls(tabs)
    if (urls.length === 0) return cmd ? [cmd] : []
    var base = cmd.length > 0 ? cmd : shellArg(String(cls).toLowerCase())
    return [stripStaleNewWindow(base) + " " + urls]
}

// ---------------------------------------------------------------------------
// Restore-time window matching
// ---------------------------------------------------------------------------

// Match one currently-open window against the snapshot's windows, returning the
// index of the best match or -1.
//
// Rules:
//   * class comparison is case-insensitive, agreeing with browserTypeForClass.
//     A case-only difference used to miss the match entirely, which left the
//     live window open AND spawned a duplicate.
//   * `matched` is a caller-owned array of already-claimed indices; a window
//     can only be claimed once.
//   * the first unmatched same-class hit is claimed as a fallback, and only an
//     exact title match overrides it - otherwise repeated scans keep clobbering
//     the pick with the LAST same-class window instead of a stable one.
function matchProfileWindow(existingWindow, profileWindows, matched) {
    if (!existingWindow || !Array.isArray(profileWindows)) return -1
    var bestIdx = -1
    var eClass = String(existingWindow.class || "").toLowerCase()
    for (var p = 0; p < profileWindows.length; p++) {
        if (matched && matched[p]) continue
        if (eClass === String(profileWindows[p].class || "").toLowerCase()) {
            if (bestIdx === -1) bestIdx = p
            if (existingWindow.title === profileWindows[p].title) {
                bestIdx = p
                break
            }
        }
    }
    return bestIdx
}