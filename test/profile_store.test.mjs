import { test } from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import {
    mkdtempSync,
    chmodSync,
    statSync,
    symlinkSync,
    lstatSync,
    truncateSync,
    rmSync,
    readdirSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

function mkfifoSync(path) {
    const r = spawnSync("mkfifo", [path])
    assert.equal(r.status, 0, "mkfifo should succeed")
}

const HELPER = fileURLToPath(new URL("../scripts/profile_store.py", import.meta.url))

function hasPython() {
    return spawnSync("python3", ["--version"]).status === 0
}

const valid = JSON.stringify({ windows: [{ class: "org.gnome.Nautilus", workspace: "3" }] })

function run(args, input) {
    return spawnSync("python3", [HELPER, ...args], {
        input,
        encoding: "utf-8",
        timeout: 10000,
    })
}

// Same as run(), but against an explicit script path (used to run a
// sabotaged copy of the helper).
function run2(args, input) {
    return spawnSync("python3", args, {
        input,
        encoding: "utf-8",
        timeout: 10000,
    })
}

function tmpStore() {
    const dir = mkdtempSync(join(tmpdir(), "wsrestorer-test-"))
    chmodSync(dir, 0o700)
    return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) }
}

// --- init ---

test("init creates a 0700 profile directory", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        const res = run(["init", dir])
        assert.equal(res.status, 0)
        assert.equal(res.stderr, "")
        const st = statSync(dir)
        assert.equal(st.mode & 0o777, 0o700)
    } finally {
        cleanup()
    }
})

// --- save / load / list / delete round trip ---

test("save, list, load, delete round trip", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const saved = run(["save", dir, "my-work"], valid)
        assert.equal(saved.status, 0, saved.stderr)

        const listed = run(["list", dir])
        assert.equal(listed.status, 0)
        assert.equal(listed.stdout.trim(), "my-work")

        const loaded = run(["load", dir, "my-work"])
        assert.equal(loaded.status, 0, loaded.stderr)
        assert.deepEqual(JSON.parse(loaded.stdout), JSON.parse(valid))

        const del = run(["delete", dir, "my-work"])
        assert.equal(del.status, 0, del.stderr)
        assert.equal(run(["list", dir]).stdout.trim(), "")
    } finally {
        cleanup()
    }
})

test("save overwrites an existing profile and leaves no temp files", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const first = run(["save", dir, "p"], valid)
        assert.equal(first.status, 0, first.stderr)

        // Overwrite with different, still-valid content.
        const replacement = JSON.stringify({ windows: [{ class: "kitty", workspace: "7" }] })
        const res = run(["save", dir, "p"], replacement)
        assert.equal(res.status, 0, res.stderr)

        // The new content is what reads back - the rename committed.
        const loaded = run(["load", dir, "p"])
        assert.equal(loaded.status, 0, loaded.stderr)
        assert.deepEqual(JSON.parse(loaded.stdout).windows[0].workspace, "7")

        // Atomic write stages through a dot-prefixed temp file and renames it
        // into place, so none may survive a successful save. A leftover here
        // means the rename never happened (or cleanup regressed).
        const leftovers = readdirSync(dir).filter(f => f !== "p.json")
        assert.deepEqual(leftovers, [], `unexpected files left behind: ${leftovers}`)
    } finally {
        cleanup()
    }
})

// The property atomicity actually buys: the destination is NEVER observed
// half-written. The old O_TRUNC implementation destroyed the old profile the
// instant it opened the file, so any failure after that point (full disk, OOM
// kill, SIGTERM) left a truncated or empty profile behind - losing both the
// old profile AND the new one. The rename-based write never touches the
// destination until a complete replacement exists.
//
// To make that observable without racing a real crash, drive the helper's
// rename step to fail and confirm the original profile is still intact and
// loadable. A truncating implementation fails this; a renaming one passes.
test("a save that fails at the commit step leaves the old profile intact", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const first = run(["save", dir, "keep"], valid)
        assert.equal(first.status, 0, first.stderr)

        // Force the commit (os.replace) to fail after the temp file is fully
        // written. os.renameat2/rename in the same directory is the only write
        // step left, so failing it isolates "staged but not committed".
        const helper = HELPER;
        const sabotage = mkdtempSync(join(tmpdir(), "wsrestorer-sabotage-"));
        try {
            // Point os.replace at a directory that does not exist by making the
            // rename target unwritable: replace the save's final step with a
            // call that raises, leaving the staged temp file behind.
            const sabotaged = join(sabotage, "sabotage_profile_store.py");
            writeFileSync(
                sabotaged,
                `import os, runpy, sys
_real = os.replace
def _boom(a, b, **kw):
    raise OSError(28, "simulated commit failure")
os.replace = _boom
sys.argv = [${JSON.stringify(helper)}] + sys.argv[1:]
try:
    runpy.run_path(${JSON.stringify(helper)}, run_name="__main__")
except SystemExit as e:
    sys.exit(e.code or 0)
`
            );
            const res = run2([sabotaged, "save", dir, "keep"], valid);
            assert.notEqual(res.status, 0, "save should fail when the commit step fails");

            // The whole point: the pre-existing profile must still be there,
            // byte-for-byte, because it was never truncated.
            const loaded = run(["load", dir, "keep"]);
            assert.equal(loaded.status, 0, loaded.stderr);
            assert.deepEqual(JSON.parse(loaded.stdout), JSON.parse(valid));
        } finally {
            rmSync(sabotage, { recursive: true, force: true });
        }
    } finally {
        cleanup()
    }
})

test("a failed save leaves the previous profile intact", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const first = run(["save", dir, "keep"], valid)
        assert.equal(first.status, 0, first.stderr)

        // Malformed JSON is rejected during validation, before any write.
        const bad = run(["save", dir, "keep"], "{not json")
        assert.notEqual(bad.status, 0)

        // The original must still load unchanged - a rejected save is not a
        // destructive one.
        const loaded = run(["load", dir, "keep"])
        assert.equal(loaded.status, 0, loaded.stderr)
        assert.deepEqual(JSON.parse(loaded.stdout), JSON.parse(valid))
        assert.deepEqual(readdirSync(dir), ["keep.json"])
    } finally {
        cleanup()
    }
})

// --- security: symlinks are never followed ---

test("save refuses to follow a planted symlink", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        symlinkSync("/etc/passwd", join(dir, "evil.json"))
        const res = run(["save", dir, "evil"], valid)
        assert.notEqual(res.status, 0)
        assert.equal(lstatSync(join(dir, "evil.json")).isSymbolicLink(), true)
    } finally {
        cleanup()
    }
})

test("load refuses a symlink and delete refuses a symlink", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        symlinkSync("/etc/passwd", join(dir, "evil.json"))
        assert.notEqual(run(["load", dir, "evil"]).status, 0)
        assert.notEqual(run(["delete", dir, "evil"]).status, 0)
        assert.equal(lstatSync(join(dir, "evil.json")).isSymbolicLink(), true)
    } finally {
        cleanup()
    }
})

// --- security: FIFOs never block (O_NONBLOCK + fstat reject) ---

test("load does not block on a FIFO", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        mkfifoSync(join(dir, "pipe.json"))
        const res = run(["load", dir, "pipe"])
        assert.notEqual(res.status, 0) // refused (non-regular), did not hang
    } finally {
        cleanup()
    }
})

// --- security: size and cardinality bounds ---

test("save round-trips a payload far larger than a pipe buffer", { skip: !hasPython() }, () => {
    // A realistic browser snapshot (6 windows x 250 tab URLs) serialises to
    // ~221 KB - well past the 64 KiB Linux pipe buffer. The QML writer streams
    // this over stdin, so the helper must read it whole regardless of how the
    // writes arrive chunked. Regression guard for large-profile saves.
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const windows = []
        for (let i = 0; i < 6; i++) {
            const tabs = []
            for (let j = 0; j < 250; j++) {
                tabs.push({ url: `https://example-site-${i}-${j}.test/some/longer/path/to/inflate`, title: `Tab ${j}` })
            }
            windows.push({ class: "firefox", workspace: String(i + 1), browser: "firefox", tabs })
        }
        const payload = JSON.stringify({ windows })
        assert.ok(payload.length > 64 * 1024, `payload should exceed a pipe buffer, got ${payload.length}`)

        const saved = run(["save", dir, "big"], payload)
        assert.equal(saved.status, 0, saved.stderr)

        const loaded = run(["load", dir, "big"])
        assert.equal(loaded.status, 0, loaded.stderr)
        const parsed = JSON.parse(loaded.stdout)
        assert.equal(parsed.windows.length, 6)
        assert.deepEqual(parsed.windows.map(w => w.tabs.length), [250, 250, 250, 250, 250, 250])
    } finally {
        cleanup()
    }
})

test("load rejects an oversized profile file", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        run(["save", dir, "big"], valid)
        const bigPath = join(dir, "big.json")
        truncateSync(bigPath, 9 * 1024 * 1024)
        const res = run(["load", dir, "big"])
        assert.notEqual(res.status, 0)
    } finally {
        cleanup()
    }
})

// MAX_PROFILE_BYTES is 8 MiB. Building a real 8 MiB *valid* profile is
// impractical (the cardinality caps make it absurd), but the bound still has
// to hold: a crafted file above it must be refused rather than read into
// memory. Checked on disk because that is the path an oversized file can
// actually arrive by.
test("an oversized profile on disk is refused", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const bigPath = join(dir, "toobig.json")
        writeFileSync(bigPath, JSON.stringify({
            windows: [{ class: "k", workspace: "1", title: "x".repeat(9 * 1024 * 1024) }],
        }))
        const res = run(["load", dir, "toobig"])
        assert.notEqual(res.status, 0)
        assert.match(res.stderr, /size bound/)
    } finally {
        cleanup()
    }
})

test("save rejects profiles that exceed cardinality bounds", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const manyWins = JSON.stringify({ windows: Array.from({ length: 600 }, () => ({})) })
        assert.notEqual(run(["save", dir, "many"], manyWins).status, 0)
        const manyTabs = JSON.stringify({ windows: [{ tabs: Array.from({ length: 400 }, () => ({})) }] })
        assert.notEqual(run(["save", dir, "manytabs"], manyTabs).status, 0)
        // An array (not an object) is not a valid profile either.
        assert.notEqual(run(["save", dir, "arr"], JSON.stringify([1, 2, 3])).status, 0)
        // Malformed JSON is rejected.
        assert.notEqual(run(["save", dir, "bad"], "{not json").status, 0)
    } finally {
        cleanup()
    }
})

test("save rejects beyond the 256 profile cap", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        for (let i = 0; i < 256; i++) {
            const r = run(["save", dir, `p${String(i).padStart(3, "0")}`], valid)
            assert.equal(r.status, 0, `save ${i}: ${r.stderr}`)
        }
        const listed = run(["list", dir]).stdout.trim().split("\n")
        assert.equal(listed.length, 256)
        // A brand-new name is refused once the cap is reached.
        assert.notEqual(run(["save", dir, "overflow"], valid).status, 0)
        // Overwriting an existing name stays allowed.
        assert.equal(run(["save", dir, "p000"], valid).status, 0)
    } finally {
        cleanup()
    }
})

test("name validation rejects traversal and unsafe names", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        for (const name of ["../escape", ".hidden", "", "has/slash", "$evil", "a b"]) {
            if (name === "") continue
            const res = run(["load", dir, name])
            assert.notEqual(res.status, 0, `should reject name: ${name}`)
        }
        assert.notEqual(run(["save", dir, "../escape"], valid).status, 0)
    } finally {
        cleanup()
    }
})