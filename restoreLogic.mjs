export function sanitizeProfileName(name) {
    if (typeof name !== "string") return null
    var n = name.trim()
    if (n.length === 0 || n.length > 128) return null
    if (n === "." || n === "..") return null
    if (n.charAt(0) === ".") return null
    if (/[\/\\\x00-\x1f]/.test(n)) return null
    if (!/^[A-Za-z0-9][A-Za-z0-9._ \-]*$/.test(n)) return null
    return n
}

export function validProfilePath(name, profileDir) {
    var safe = sanitizeProfileName(name)
    if (safe === null) return null
    var base = profileDir
    var resolved = base + "/" + safe + ".json"
    if (resolved.indexOf(base) !== 0) return null
    return resolved
}

export function shellArg(s) {
    if (s === null || s === undefined) return "''"
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

export function sanitizeLaunchCommand(raw, fallbackClass) {
    var src = raw || (fallbackClass ? fallbackClass.toLowerCase() : "")
    var tokens = String(src).split(/\s+/).filter(function (t) { return t.length > 0 })
    if (tokens.length === 0) return ""
    if (!/^(\.?\/)?[A-Za-z0-9_][A-Za-z0-9_.+/-]*$/.test(tokens[0])) return ""
    var out = []
    for (var i = 0; i < tokens.length; i++) out.push(shellArg(tokens[i]))
    return out.join(" ")
}

export function safeWorkspace(ws) {
    if (typeof ws !== "string") return null
    if (!/^[_a-z0-9]{1,32}$/i.test(ws)) return null
    return ws
}

export function safeClass(cls) {
    if (typeof cls !== "string") return null
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(cls)) return null
    return cls
}

export function numOr(v) {
    var n = Number(v)
    return isFinite(n) ? Math.round(n) : 0
}

export function profileIconFor(name) {
    var n = (name || "").toLowerCase()
    if (/code|dev|coding|prog|program|project/.test(n)) return "\ue796"
    if (/work|office|job/.test(n)) return "\uf0c0"
    if (/photo|image|picture|gimp|design|edit|art|draw/.test(n)) return "\uf1c5"
    if (/music|audio|song|media/.test(n)) return "\ue602"
    if (/game|play|gaming/.test(n)) return "\uf11b"
    if (/web|internet|www|browser|search/.test(n)) return "\ue700"
    if (/video|movie|film|stream/.test(n)) return "\uf03d"
    if (/term|shell|cli|console/.test(n)) return "\uf120"
    if (/chat|discord|telegram|message|slack/.test(n)) return "\uf086"
    if (/doc|note|write|text|paper/.test(n)) return "\uf15c"
    if (/file|folder|fm|nautilus|browse/.test(n)) return "\uf07b"
    if (/mail|email|gmail/.test(n)) return "\uf0e0"
    if (/home|default/.test(n)) return "\uf015"
    return "\uf2db"
}

export function generateDefaultName(date) {
    var d = date || new Date()
    var pad = function (n) { return n < 10 ? "0" + n : "" + n }
    return "snapshot-" + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
        "-" + pad(d.getHours()) + pad(d.getMinutes())
}

export function cleanCmd(raw) {
    if (!raw) return null
    var v = raw.replace(/\s+/g, " ").trim()
    return v.length ? v : null
}

export function buildMonitorMap(monitors) {
    var map = {}
    for (var i = 0; i < monitors.length; i++) {
        map[monitors[i].id] = monitors[i].name
    }
    return map
}

// Class-name sets for browser detection. Matches Firefox-family and
// Chromium-family browsers by their Hyprland window class.
const FIREFOX_CLASSES = /^(firefox|librewolf|waterfox|floorp|tor-browser|zen|palemoon|seamonkey)(\.|-|$)/i
const CHROMIUM_CLASSES = /(chrom|brave|vivaldi|edge|opera|electron)/i

// Return the browser engine type for a window class: "firefox", "chromium",
// or null if it isn't a browser we can tab-capture.
export function browserTypeForClass(cls) {
    if (typeof cls !== "string" || cls.length === 0) return null
    if (FIREFOX_CLASSES.test(cls)) return "firefox"
    if (CHROMIUM_CLASSES.test(cls)) return "chromium"
    return null
}

// Validate a tab URL before it is injected into a launch command. Accepts
// http/https and a conservative set of safe schemes, and rejects anything with
// shell metacharacters or whitespace so a crafted/compromised URL can never
// break out of the generated bash. Returns the trimmed URL or null.
export function safeUrl(url) {
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
export function buildTabUrls(tabs) {
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

// Given a base launch command string and a browser window snapshot, append the
// tab URLs with --new-window when tabs are present. Returns the augmented
// command ("" if nothing usable). Used by restore to reopen a browser's pages.
export function buildBrowserLaunchCommand(pureCommand, cls, tabs) {
    var cmd = pureCommand || ""
    var type = browserTypeForClass(cls)
    if (!type) return cmd
    var urls = buildTabUrls(tabs)
    if (urls.length === 0) return cmd
    // If the base command is empty, fall back to the browser executable name.
    var base = cmd.length > 0 ? cmd : "'" + cls.toLowerCase() + "'"
    // Strip a stale `--new-window <urls>` tail left over from a previous
    // restore (the captured /proc cmdline still carries it), otherwise we'd
    // append another URL list and reopen duplicates.
    var marker = base.indexOf(" --new-window ")
    if (marker !== -1) base = base.slice(0, marker)
    return base + " --new-window " + urls
}

