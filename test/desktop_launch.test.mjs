// Tests for scripts/desktop_launch.py - the trusted desktop-entry collector.
//
// The collector is the trust anchor for restore: it is the only thing allowed
// to name an executable, so it must only ever surface entries from the
// freedesktop application database and must never expand field codes into
// something executable. Runs the real module against a temp tree so no test
// depends on what happens to be installed on the machine.

import { strict as assert } from "node:assert"
import { test } from "node:test"
import { execFileSync } from "node:child_process"
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

const SCRIPT = resolve(import.meta.dirname, "..", "scripts", "desktop_launch.py")

function withTree(files, fn) {
    const root = mkdtempSync(join(tmpdir(), "wsr-desktop-"))
    try {
        const apps = join(root, "apps")
        mkdirSync(apps, { recursive: true })
        for (const [name, body] of Object.entries(files)) {
            writeFileSync(join(apps, name), body)
        }
        return fn(apps)
    } finally {
        rmSync(root, { recursive: true, force: true })
    }
}

function build(dirs) {
    // The module is loaded through a child process so the test exercises the
    // real argparse-free CLI surface, matching how BarWidget.qml invokes it.
    const out = execFileSync("python3", ["-c", `
import json, sys
sys.path.insert(0, ${JSON.stringify(resolve(import.meta.dirname, "..", "scripts"))})
import desktop_launch
print(json.dumps(desktop_launch.build_index(${JSON.stringify(dirs)})))
`], { encoding: "utf8" })
    return JSON.parse(out)
}

test("collects Exec from a plain application entry", () => {
    withTree({
        "firefox.desktop": "[Desktop Entry]\nType=Application\nName=Firefox\nExec=/usr/lib/firefox/firefox\n",
    }, (dirs) => {
        const idx = build([dirs])
        assert.equal(idx["name:firefox"][0], "/usr/lib/firefox/firefox")
    })
})

test("indexes StartupWMClass as well as the file name", () => {
    withTree({
        "com.example.App.desktop":
            "[Desktop Entry]\nType=Application\nExec=/opt/app/bin/app\nStartupWMClass=ExampleApp\n",
    }, (dirs) => {
        const idx = build([dirs])
        assert.equal(idx["wmclass:exampleapp"][0], "/opt/app/bin/app")
        assert.equal(idx["name:com.example.app"][0], "/opt/app/bin/app")
    })
})

test("skips KDE's @@startup_wm_class placeholder", () => {
    withTree({
        "thing.desktop":
            "[Desktop Entry]\nType=Application\nExec=/usr/bin/thing\nStartupWMClass=@@startup_wm_class\n",
    }, (dirs) => {
        const idx = build([dirs])
        assert.equal(idx["wmclass:thing"], undefined)
        assert.equal(idx["wmclass:@@startup_wm_class"], undefined)
        assert.equal(idx["name:thing"][0], "/usr/bin/thing")
    })
})

test("strips field codes rather than leaving them for the caller", () => {
    withTree({
        "browser.desktop":
            "[Desktop Entry]\nType=Application\nExec=/usr/bin/browser %U\n",
    }, (dirs) => {
        const idx = build([dirs])
        assert.equal(idx["name:browser"][0], "/usr/bin/browser")
        assert.ok(!idx["name:browser"][0].includes("%U"))
    })
})

test("ignores non-Application, Hidden and malformed entries", () => {
    withTree({
        "link.desktop": "[Desktop Entry]\nType=Link\nURL=https://example.com\n",
        "dir.desktop": "[Desktop Entry]\nType=Directory\n",
        "hidden.desktop": "[Desktop Entry]\nType=Application\nHidden=true\nExec=/usr/bin/hidden\n",
        "noexec.desktop": "[Desktop Entry]\nType=Application\nName=Nothing\n",
        "notadesktop.txt": "Type=Application\nExec=/usr/bin/nope\n",
    }, (dirs) => {
        const idx = build([dirs])
        assert.deepEqual(Object.keys(idx), [])
    })
})

test("later directories win on a name collision", () => {
    withTree({
        "app.desktop": "[Desktop Entry]\nType=Application\nExec=/usr/bin/first\n",
    }, (dirs) => {
        const userDir = dirs + "-user"
        mkdirSync(userDir, { recursive: true })
        writeFileSync(join(userDir, "app.desktop"),
            "[Desktop Entry]\nType=Application\nExec=/usr/bin/second\n")
        const idx = build([dirs, userDir])
        assert.equal(idx["name:app"][0], "/usr/bin/second")
        rmSync(userDir, { recursive: true, force: true })
    })
})

test("does not let a StartupWMClass overwrite a real name key", () => {
    withTree({
        "zzz.desktop":
            "[Desktop Entry]\nType=Application\nExec=/usr/bin/zzz\nStartupWMClass=real\n",
        "real.desktop": "[Desktop Entry]\nType=Application\nExec=/usr/bin/real\n",
    }, (dirs) => {
        const idx = build([dirs])
        assert.equal(idx["wmclass:real"][0], "/usr/bin/zzz")
        assert.equal(idx["name:real"][0], "/usr/bin/real")
    })
})

test("tolerates a missing or unreadable directory", () => {
    const idx = build(["/nonexistent/does/not/exist"])
    assert.deepEqual(idx, {})
})