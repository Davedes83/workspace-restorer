import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { createContext, runInContext } from "node:vm"
import { fileURLToPath } from "node:url"

// restoreLogic.js is a QML JS library: it cannot use `export` (a hard load
// error in QML) and carries `//.pragma library` so node can evaluate it too.
// So it is loaded by evaluating the source and reading the declarations off the
// resulting global scope rather than through an ESM import. That means these
// tests exercise the EXACT file BarWidget.qml imports - there is no second copy
// that can drift.
const LOGIC_PATH = fileURLToPath(new URL("../restoreLogic.js", import.meta.url))
const logic = createContext({})
runInContext(readFileSync(LOGIC_PATH, "utf8"), logic)

const {
    sanitizeProfileName,
    shellArg,
    sanitizeLaunchCommand,
    safeWorkspace,
    safeClass,
    numOr,
    profileIconFor,
    generateDefaultName,
    cleanCmd,
    browserTypeForClass,
    safeUrl,
    buildTabUrls,
    buildBrowserLaunchCommands,
    enforceProfileCardinality,
    matchProfileWindow,
    stripStaleNewWindow,
    MAX_WINDOWS,
    MAX_TABS_PER_WINDOW,
} = logic

const DIR = "/home/user/.config/omarchy/workspace-restorer"

// --- sanitizeProfileName ---

test("sanitizeProfileName accepts valid names", () => {
    for (const name of ["coding", "my work", "proj.1", "Media-2", "A", "a1_b2.c3"]) {
        assert.equal(sanitizeProfileName(name), name.trim())
    }
})

test("sanitizeProfileName trims whitespace", () => {
    assert.equal(sanitizeProfileName("  coding  "), "coding")
})

test("sanitizeProfileName rejects non-strings", () => {
    assert.equal(sanitizeProfileName(null), null)
    assert.equal(sanitizeProfileName(undefined), null)
    assert.equal(sanitizeProfileName(123), null)
    assert.equal(sanitizeProfileName({}), null)
})

test("sanitizeProfileName rejects empty / whitespace-only", () => {
    assert.equal(sanitizeProfileName(""), null)
    assert.equal(sanitizeProfileName("   "), null)
})

test("sanitizeProfileName rejects path traversal and separators", () => {
    for (const name of ["..", ".", "../evil", "a/b", "a\\b", "a,b", "a;b"]) {
        assert.equal(sanitizeProfileName(name), null, `should reject: ${name}`)
    }
})

test("sanitizeProfileName rejects hidden files and control chars", () => {
    assert.equal(sanitizeProfileName(".hidden"), null)
    assert.equal(sanitizeProfileName("a\x00b"), null)
    assert.equal(sanitizeProfileName("a\nb"), null)
    assert.equal(sanitizeProfileName("a\tb"), null)
})

test("sanitizeProfileName rejects overly long names", () => {
    assert.equal(sanitizeProfileName("a".repeat(129)), null)
    assert.equal(sanitizeProfileName("a".repeat(128)), "a".repeat(128))
})

test("sanitizeProfileName rejects shell/special metacharacters", () => {
    for (const name of ["x$y", "x`y", "x$(y)", "x|y", "x<y", "x>y", "x&y", "x!y", "x~y", "x%y", "x@y", "x#y", "x?y", "x*y", "x'y", 'x"y']) {
        assert.equal(sanitizeProfileName(name), null, `should reject: ${name}`)
    }
})

// --- shellArg ---

test("shellArg single-quotes and escapes embedded quotes", () => {
    assert.equal(shellArg("hello"), "'hello'")
    assert.equal(shellArg("it's"), "'it'\\''s'")
    assert.equal(shellArg("$(rm -rf /)"), "'$(rm -rf /)'")
})

test("shellArg handles null/undefined as empty string", () => {
    assert.equal(shellArg(null), "''")
    assert.equal(shellArg(undefined), "''")
})

// --- sanitizeLaunchCommand ---

test("sanitizeLaunchCommand builds safe quoted command", () => {
    assert.equal(sanitizeLaunchCommand("nautilus --new-window"), "'nautilus' '--new-window'")
})

test("sanitizeLaunchCommand accepts ./rel paths and names", () => {
    assert.equal(sanitizeLaunchCommand("./bin/app run"), "'./bin/app' 'run'")
    assert.equal(sanitizeLaunchCommand("app"), "'app'")
})

test("sanitizeLaunchCommand rejects unsafe executables", () => {
    for (const raw of ["$(evil)", "evil$(x)", "evil;ls", "evil|cat", "evil`x`", "evil&", "evil>out", "evil<in", "evil'", "1bad-token!"]) {
        assert.equal(sanitizeLaunchCommand(raw), "", `should reject: ${raw}`)
    }
})

test("sanitizeLaunchCommand accepts multi-arg valid commands", () => {
    assert.equal(sanitizeLaunchCommand("x y"), "'x' 'y'")
})

test("sanitizeLaunchCommand falls back to class when empty", () => {
    assert.equal(sanitizeLaunchCommand("", "Firefox"), "'firefox'")
    assert.equal(sanitizeLaunchCommand(null, "Code"), "'code'")
})

test("sanitizeLaunchCommand returns empty on no input", () => {
    assert.equal(sanitizeLaunchCommand("", ""), "")
    assert.equal(sanitizeLaunchCommand("   ", "   "), "")
})

// --- safeWorkspace ---

test("safeWorkspace accepts plain workspaces", () => {
    assert.equal(safeWorkspace("1"), "1")
    assert.equal(safeWorkspace("my_work2"), "my_work2")
})

test("safeWorkspace rejects unsafe/empty/oversized", () => {
    assert.equal(safeWorkspace(""), null)
    assert.equal(safeWorkspace(null), null)
    assert.equal(safeWorkspace("a".repeat(33)), null)
    for (const ws of ["a b", "a;b", "a/b", "$x", "x'y", "a-b", "a.b", "aéb"]) {
        assert.equal(safeWorkspace(ws), null, `should reject: ${ws}`)
    }
})

// --- safeClass ---

test("safeClass accepts plain classes", () => {
    assert.equal(safeClass("firefox"), "firefox")
    assert.equal(safeClass("org.gnome.Nautilus"), "org.gnome.Nautilus")
})

test("safeClass rejects unsafe/oversized", () => {
    assert.equal(safeClass(""), null)
    assert.equal(safeClass(null), null)
    assert.equal(safeClass("a".repeat(129)), null)
    for (const cls of ["a b", "a'b", "a$b", "a(b)", "a;b", "a`b", "a|b", "a*b", "a!b"]) {
        assert.equal(safeClass(cls), null, `should reject: ${cls}`)
    }
})

// --- numOr ---

test("numOr rounds finite numbers", () => {
    assert.equal(numOr("42"), 42)
    assert.equal(numOr(42.7), 43)
    assert.equal(numOr("12.4"), 12)
    assert.equal(numOr(0), 0)
})

test("numOr returns 0 for non-finite", () => {
    assert.equal(numOr("abc"), 0)
    assert.equal(numOr(null), 0)
    assert.equal(numOr(undefined), 0)
    assert.equal(numOr(NaN), 0)
    assert.equal(numOr(Infinity), 0)
})

// --- profileIconFor ---

test("profileIconFor picks keyword-based glyphs", () => {
    assert.equal(profileIconFor("coding"), "\ue796")
    assert.equal(profileIconFor("Work"), "\uf0c0")
    assert.equal(profileIconFor("media"), "\ue602")
    assert.equal(profileIconFor("game"), "\uf11b")
    assert.equal(profileIconFor("terminal"), "\uf120")
})

test("profileIconFor falls back to default", () => {
    assert.equal(profileIconFor("randomxyz"), "\uf2db")
    assert.equal(profileIconFor(""), "\uf2db")
    assert.equal(profileIconFor(null), "\uf2db")
})

// --- generateDefaultName ---

test("generateDefaultName produces snapshot-YYYYMMDD-HHMM", () => {
    const d = new Date(2026, 7, 29, 9, 5) // Aug 29 2026, 09:05
    const name = generateDefaultName(d)
    assert.match(name, /^snapshot-\d{8}-\d{4}$/)
    assert.equal(name, "snapshot-20260829-0905")
})

// --- cleanCmd ---

test("cleanCmd collapses whitespace and trims", () => {
    assert.equal(cleanCmd("  a    b  "), "a b")
    assert.equal(cleanCmd("single  word"), "single word")
})

test("cleanCmd returns null for empty/invalid", () => {
    assert.equal(cleanCmd(""), null)
    assert.equal(cleanCmd("   "), null)
    assert.equal(cleanCmd(null), null)
})

// --- browserTypeForClass ---

test("browserTypeForClass detects Firefox family", () => {
    for (const cls of ["firefox", "Firefox", "librewolf", "floorp", "zen", "tor-browser", "firefox-esr"]) {
        assert.equal(browserTypeForClass(cls), "firefox", `should be firefox: ${cls}`)
    }
})

test("browserTypeForClass detects Chromium family", () => {
    for (const cls of ["google-chrome", "chromium", "brave-browser", "vivaldi", "microsoft-edge", "Google-chrome"]) {
        assert.equal(browserTypeForClass(cls), "chromium", `should be chromium: ${cls}`)
    }
})

test("browserTypeForClass rejects non-browsers", () => {
    for (const cls of ["nautilus", "kitty", "code", "", null, "slack"]) {
        assert.equal(browserTypeForClass(cls), null, `should be null: ${cls}`)
    }
})

// --- safeUrl ---

test("safeUrl accepts http/https URLs", () => {
    assert.equal(safeUrl("https://github.com/foo?q=1#x"), "https://github.com/foo?q=1#x")
    assert.equal(safeUrl("http://example.com/a b"), null) // space rejected
})

test("safeUrl accepts safe special schemes", () => {
    assert.equal(safeUrl("about:blank"), "about:blank")
    assert.equal(safeUrl("about:newtab"), "about:newtab")
    assert.equal(safeUrl("file:///home/user/x"), "file:///home/user/x")
    assert.equal(safeUrl("chrome://settings"), "chrome://settings")
    assert.equal(safeUrl("moz-extension://abc/"), "moz-extension://abc/")
})

test("safeUrl rejects shell metacharacters and garbage", () => {
    for (const url of ["https://x.com/';rm -rf /", "https://x.com/$(x)", "https://x.com/`x`", "https://x.com/a|b", "https://x.com/a&b", "https://x.com/a;b", "https://x.com/a\nb", "not-a-url", "", null, "https://x.com/ x"]) {
        assert.equal(safeUrl(url), null, `should reject: ${url}`)
    }
    assert.equal(safeUrl("ftp://x.com"), "ftp://x.com")
})

// --- buildTabUrls ---

test("buildTabUrls quotes valid URLs and skips blanks", () => {
    const tabs = [
        { url: "https://github.com/" },
        { url: "about:newtab" },
        { url: null },
        { url: "https://x.com/'drop" },
        { url: "https://news.ycombinator.com/" },
    ]
    assert.equal(buildTabUrls(tabs), "'https://github.com/' 'https://news.ycombinator.com/'")
})

test("buildTabUrls returns empty for no usable tabs", () => {
    assert.equal(buildTabUrls([]), "")
    assert.equal(buildTabUrls(null), "")
    assert.equal(buildTabUrls([{ url: "about:newtab" }]), "")
    assert.equal(buildTabUrls([{ url: "https://x.com/;ls" }]), "")
})

// --- stripStaleNewWindow ---

test("stripStaleNewWindow removes a stale --new-window tail", () => {
    const polluted = "'/opt/vivaldi/vivaldi-bin' --new-window 'https://a/' 'https://b/'"
    assert.equal(
        stripStaleNewWindow(polluted),
        "'/opt/vivaldi/vivaldi-bin'"
    )
})

test("stripStaleNewWindow leaves a clean command untouched", () => {
    assert.equal(stripStaleNewWindow("'firefox'"), "'firefox'")
    assert.equal(stripStaleNewWindow("'firefox' --profile dev"), "'firefox' --profile dev")
})

// --- enforceProfileCardinality ---

test("enforceProfileCardinality accepts a bounded profile", () => {
    const profile = {
        windows: [
            { class: "kitty", workspace: "1" },
            { class: "firefox", workspace: "2", tabs: [{ url: "https://x.com/" }] },
        ],
    }
    assert.equal(enforceProfileCardinality(profile), profile)
    assert.equal(MAX_WINDOWS, 512)
    assert.equal(MAX_TABS_PER_WINDOW, 300)
})

test("enforceProfileCardinality rejects non-object / missing windows", () => {
    assert.equal(enforceProfileCardinality(null), null)
    assert.equal(enforceProfileCardinality([]), null)
    assert.equal(enforceProfileCardinality("x"), null)
    assert.equal(enforceProfileCardinality({}), null)
    assert.equal(enforceProfileCardinality({ windows: "nope" }), null)
    assert.equal(enforceProfileCardinality({ windows: [null] }), null)
})

test("enforceProfileCardinality rejects too many windows", () => {
    const windows = Array.from({ length: MAX_WINDOWS + 1 }, () => ({ class: "kitty" }))
    assert.equal(enforceProfileCardinality({ windows }), null)
    const ok = Array.from({ length: MAX_WINDOWS }, () => ({ class: "kitty" }))
    assert.equal(enforceProfileCardinality({ windows: ok }) === null, false)
})

test("enforceProfileCardinality rejects tabs beyond the per-window cap", () => {
    const window = Array.from({ length: MAX_TABS_PER_WINDOW }, () => ({ url: "https://x.com/" }))
    assert.equal(enforceProfileCardinality({ windows: [{ tabs: window }] }) === null, false)
    const over = Array.from({ length: MAX_TABS_PER_WINDOW + 1 }, () => ({ url: "https://x.com/" }))
    assert.equal(enforceProfileCardinality({ windows: [{ tabs: over }] }), null)
})

// --- buildBrowserLaunchCommands ---
//
// NOTE: results are spread with [...] before comparison. The logic runs in a
// separate vm realm, so its arrays carry that realm's Array.prototype and
// assert/strict's deepStrictEqual rejects them as a prototype mismatch even
// when the contents are identical. Spreading copies into a local-realm array.

test("buildBrowserLaunchCommands passes all URLs without --new-window for Chromium", () => {
    const tabs = [{ url: "https://github.com/" }, { url: "https://www.reddit.com/" }]
    assert.deepEqual(
        [...buildBrowserLaunchCommands("'google-chrome'", "Google-chrome", tabs)],
        ["'google-chrome' 'https://github.com/' 'https://www.reddit.com/'"]
    )
})

test("buildBrowserLaunchCommands keeps a single Chromium tab in one command", () => {
    const tabs = [{ url: "https://github.com/" }]
    assert.deepEqual(
        [...buildBrowserLaunchCommands("'google-chrome'", "Google-chrome", tabs)],
        ["'google-chrome' 'https://github.com/'"]
    )
})

test("buildBrowserLaunchCommands passes all URLs without --new-window for Firefox (no split windows)", () => {
    const tabs = [{ url: "https://github.com/" }, { url: "https://www.reddit.com/" }]
    assert.deepEqual(
        [...buildBrowserLaunchCommands("'firefox'", "firefox", tabs)],
        ["'firefox' 'https://github.com/' 'https://www.reddit.com/'"]
    )
})

test("buildBrowserLaunchCommands returns base command unchanged for non-browsers or no tabs", () => {
    assert.deepEqual([...buildBrowserLaunchCommands("'nautilus'", "nautilus", [{ url: "https://x.com" }])], ["'nautilus'"])
    assert.deepEqual([...buildBrowserLaunchCommands("'firefox'", "firefox", [])], ["'firefox'"])
    assert.deepEqual([...buildBrowserLaunchCommands("", "nautilus", [{ url: "https://x.com" }])], [])
})

// --- matchProfileWindow ---

test("matchProfileWindow matches on class", () => {
    const profile = [{ class: "kitty", title: "term" }, { class: "firefox", title: "web" }]
    assert.equal(matchProfileWindow({ class: "firefox", title: "web" }, profile, [false, false]), 1)
    assert.equal(matchProfileWindow({ class: "kitty", title: "term" }, profile, [false, false]), 0)
})

test("matchProfileWindow matches class case-insensitively", () => {
    // Regression: a case-only difference used to miss the match entirely, which
    // left the live window open AND spawned a duplicate.
    const profile = [{ class: "Firefox", title: "web" }, { class: "Google-chrome", title: "browse" }]
    assert.equal(matchProfileWindow({ class: "firefox", title: "web" }, profile, [false, false]), 0)
    assert.equal(matchProfileWindow({ class: "FIREFOX", title: "web" }, profile, [false, false]), 0)
    assert.equal(matchProfileWindow({ class: "google-chrome", title: "browse" }, profile, [false, false]), 1)
})

test("matchProfileWindow prefers an exact title match among same-class windows", () => {
    const profile = [
        { class: "kitty", title: "first" },
        { class: "kitty", title: "second" },
    ]
    const matched = [false, false]
    assert.equal(matchProfileWindow({ class: "kitty", title: "second" }, profile, matched), 1)
})

test("matchProfileWindow falls back to the first unmatched same-class window", () => {
    const profile = [
        { class: "kitty", title: "first" },
        { class: "kitty", title: "second" },
    ]
    const matched = [false, false]
    assert.equal(matchProfileWindow({ class: "kitty", title: "no-such-title" }, profile, matched), 0)
})

test("matchProfileWindow skips already-claimed profile windows", () => {
    const profile = [
        { class: "kitty", title: "first" },
        { class: "kitty", title: "second" },
    ]
    // First window already consumed profile[0], so the next kitty must take [1]
    // rather than re-matching the claimed one.
    const matched = [true, false]
    assert.equal(matchProfileWindow({ class: "kitty", title: "second" }, profile, matched), 1)
})

test("matchProfileWindow returns -1 when nothing matches", () => {
    const profile = [{ class: "kitty", title: "term" }]
    assert.equal(matchProfileWindow({ class: "firefox", title: "web" }, profile, [false]), -1)
    assert.equal(matchProfileWindow(null, profile, [false]), -1)
    assert.equal(matchProfileWindow({ class: "kitty" }, null, [false]), -1)
})
