import { test } from "node:test"
import assert from "node:assert/strict"
import {
    sanitizeProfileName,
    validProfilePath,
    shellArg,
    sanitizeLaunchCommand,
    safeWorkspace,
    safeClass,
    numOr,
    profileIconFor,
    generateDefaultName,
    cleanCmd,
    buildMonitorMap,
} from "../restoreLogic.mjs"

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

// --- validProfilePath ---

test("validProfilePath builds a contained .json path", () => {
    assert.equal(validProfilePath("coding", DIR), DIR + "/coding.json")
})

test("validProfilePath returns null for invalid names", () => {
    assert.equal(validProfilePath("..", DIR), null)
    assert.equal(validProfilePath("../evil", DIR), null)
    assert.equal(validProfilePath("", DIR), null)
    assert.equal(validProfilePath(null, DIR), null)
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

// --- buildMonitorMap ---

test("buildMonitorMap maps monitor id to name", () => {
    const monitors = [{ id: 0, name: "DP-1" }, { id: 1, name: "HDMI-A-1" }]
    assert.deepEqual(buildMonitorMap(monitors), { 0: "DP-1", 1: "HDMI-A-1" })
})
