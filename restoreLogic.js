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

// Build a safe relaunch command line from an editable profile "command".
// The executable token is restricted to a plain path/name (no shell
// metacharacters) and every token is shell-quoted, so a crafted profile cannot
// smuggle in $(...), backticks, ;, |, redirections, etc. Returns a
// ready-to-execute command string, or "" if nothing usable.
function sanitizeLaunchCommand(raw, fallbackClass) {
    var src = raw || (fallbackClass ? fallbackClass.toLowerCase() : "")
    var tokens = String(src).split(/\s+/).filter(function (t) { return t.length > 0 })
    if (tokens.length === 0) return ""
    // First token is the executable: must be a plain name or ./-relative path.
    if (!/^(\.?\/)?[A-Za-z0-9_][A-Za-z0-9_.+/-]*$/.test(tokens[0])) return ""
    var out = []
    for (var i = 0; i < tokens.length; i++) out.push(shellArg(tokens[i]))
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

// Clean a captured /proc cmdline into a safe relaunch string: collapses
// internal whitespace (single spaces) and trims. Returns null when empty.
function cleanCmd(raw) {
    if (!raw) return null
    var v = raw.replace(/\s+/g, " ").trim()
    return v.length ? v : null
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

// Strip a stale `--new-window <urls>` tail left over from a previous restore
// (the captured /proc cmdline still carries it), otherwise we'd append another
// URL list and reopen duplicates.
function stripStaleNewWindow(base) {
    var marker = base.indexOf(" --new-window ")
    return marker === -1 ? base : base.slice(0, marker)
}

// Returns an array of shell commands to run in sequence (one launch step per
// element), which the restore script executes line by line. When the browser is
// already running (the common case), passing `--new-window url1 url2` to Firefox
// opens ONE window per URL, and Vivaldi's own session restore may add extra
// tabs. So all URLs are passed without `--new-window` to open as tabs in the
// existing window (single window, all tabs, no duplicates). When the browser is
// not running, the same command opens one fresh window with all tabs.
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