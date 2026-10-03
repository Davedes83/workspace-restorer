import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
// Single source of truth for the security-critical validators and command
// builders. This file is the SAME one the node test suite exercises, so the
// tests guard the code that actually runs. It cannot use `export` (that is a
// hard load error in a QML JS library) and carries `//.pragma library` so node
// can still evaluate it; see the header comment in restoreLogic.js.
import "restoreLogic.js" as Logic

Panel {
    id: root

    moduleName: "davedes.workspace-restorer"
    ipcTarget: "workspace-restorer"

    property var profiles: []
    property bool isSnapshotting: false
    property bool isRestoring: false
    property string lastAction: ""
    property string profileDir: Quickshell.env("HOME") + "/.config/omarchy/workspace-restorer"
    // Path to the hardened profile store helper. All profile-dir reads and
    // writes go through it (never a shell `ls`/`cat`/`rm` on user paths); it
    // no-follow-opens, fstats for regular/user-owned files, bounds sizes and
    // cardinality, and routes save payloads over stdin (no temp files).
    readonly property string storeScript: Qt.resolvedUrl("scripts/profile_store.py").toString().replace(/^file:\/\//, "")
    property var pendingSnapshot: null
    property bool showingNameInput: false
    property var _monitorsCaptured: []

    readonly property color hoverBg: bar
        ? Style.hoverFillFor(bar.foreground, Color.accent)
        : Qt.darker(Color.bar.text, 1.1)
    readonly property color selectedBg: bar
        ? Style.selectedFillFor(bar.foreground, Color.accent)
        : Qt.darker(Color.bar.text, 1.15)
    // Destructive hover tint. Derived from the palette's urgent role rather
    // than the old hardcoded "#663333", so it follows the active theme.
    readonly property color deleteBg: Util.alpha(Color.urgent, 0.22)

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    Component.onCompleted: {
        ensureProfileDir()
    }

    // Dismissing the panel while the save prompt is open used to leave the
    // prompt (and the captured snapshot) alive: nothing reset them except Save
    // or Cancel, so reopening the panel minutes later offered to save a layout
    // capture that was long stale. Discard on close instead.
    Connections {
        target: root
        function onOpenedChanged() {
            if (!root.opened && root.showingNameInput) {
                root.showingNameInput = false
                root.pendingSnapshot = null
            }
        }
    }

    // Guarantee the profile directory exists before any save/read. Uses the
    // store helper (not a shell mkdir) so the directory is created 0700 and
    // re-lstat-checked; the profile listing is chained onto its success so the
    // first load never races the directory creation.
    function ensureProfileDir() {
        initProc.command = ["python3", root.storeScript, "init", root.profileDir]
        initProc.running = true
    }

    Process {
        id: initProc
        onExited: function(exitCode) {
            if (exitCode === 0) root.refreshProfiles()
        }
    }

    function notify(summary, body) {
        Quickshell.execDetached(["notify-send", "-a", "Workspace Restorer", "-i", "preferences-desktop-workspaces", summary, body || ""])
    }

    // ------------------------------------------------------------------
    // Shared logic delegates
    //
    // These thin wrappers keep the call sites below readable while the
    // implementations live in restoreLogic.js - the SAME file the node test
    // suite exercises. There is exactly one copy of every validator now, so a
    // fix or a hardening change cannot apply to the tests but not to the
    // running widget, which is exactly how the two copies drifted before.
    // ------------------------------------------------------------------

    function sanitizeProfileName(name) { return Logic.sanitizeProfileName(name) }

    // Nested-cardinality guard, defense in depth on the consuming side. The
    // store helper enforces the same caps on save and load.
    function enforceProfileCardinality(profile) { return Logic.enforceProfileCardinality(profile) }

    function shellArg(s) { return Logic.shellArg(s) }

    function sanitizeLaunchCommand(raw, fallbackClass) { return Logic.sanitizeLaunchCommand(raw, fallbackClass) }

    function safeUrl(url) { return Logic.safeUrl(url) }

    function buildTabUrls(tabs) { return Logic.buildTabUrls(tabs) }

    // URLs are passed WITHOUT --new-window: when the browser is already running,
    // Firefox turns that into one window per URL and Vivaldi adds its own
    // session-restore tabs. Plain arguments open as tabs in the existing window.
    function buildBrowserLaunchCommands(pureCommand, cls, tabs) {
        return Logic.buildBrowserLaunchCommands(pureCommand, cls, tabs)
    }

    function safeWorkspace(ws) { return Logic.safeWorkspace(ws) }

    function safeClass(cls) { return Logic.safeClass(cls) }

    function numOr(v) { return Logic.numOr(v) }

    function profileIconFor(name) { return Logic.profileIconFor(name) }

    function generateDefaultName() { return Logic.generateDefaultName() }

    // Return the browser engine for a window class: "firefox", "chromium", or
    // null if the window isn't a supported browser.
    function browserTypeForClass(cls) { return Logic.browserTypeForClass(cls) }

    // Resolve the profile/user-data directory for a browser window from its
    // captured /proc cmdline. For Chromium this is the --user-data-dir value
    // (or the default ~/.config/<app>); for Firefox the -P/-profile path or the
    // default ~/.mozilla/firefox/<default-profile>. Returns a safe-ish absolute
    // path or null. Never used in shell generation - only to locate the
    // session/debug files for tab capture.
    function resolveBrowserProfile(btype, cmdline) {
        var home = Quickshell.env("HOME")
        var cmd = String(cmdline || "")
        var m
        if (btype === "chromium") {
            m = /--user-data-dir=("?)([^"\s]+)\1/.exec(cmd)
            if (m) return m[2]
            if (/google-chrome/i.test(cmd)) return home + "/.config/google-chrome"
            if (/chromium/i.test(cmd)) return home + "/.config/chromium"
            if (/brave/i.test(cmd)) return home + "/.config/BraveSoftware/Brave-Browser"
            if (/vivaldi/i.test(cmd)) return home + "/.config/vivaldi"
            if (/edge/i.test(cmd)) return home + "/.config/microsoft-edge"
            if (/opera/i.test(cmd)) return home + "/.config/opera"
            return null
        } else if (btype === "firefox") {
            m = /--profile(=|\s+)(\S+)/.exec(cmd)
            if (m) return m[2]
            m = /-P\s+(\S+)/.exec(cmd)
            if (m) return home + "/.mozilla/firefox/" + m[1]
            // Default: pick the default* profile dir if present.
            var base = home + "/.mozilla/firefox"
            return base
        }
        return null
    }

    // --- Bar Button ---

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󰆞"
        onPressed: function(b) {
            root.toggle()
        }
    }

    // --- Popup Panel ---

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        contentWidth: 280
        contentHeight: showingNameInput ? 220 : 400

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
        }

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            visible: !root.showingNameInput

            PanelHero {
                title: root.isRestoring ? "Restoring..." : "Workspace Restorer"
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Qt.darker(Color.bar.text, 1.15)
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: root.isRestoring ? Qt.darker(Color.bar.background, 1.15) : root.hoverBg

                Row {
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: root.isSnapshotting ? "󰏇" : root.isRestoring ? "󰑐" : "󰅧"
                        color: Color.bar.text
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: root.isSnapshotting ? "Capturing..." : root.isRestoring ? "Restoring..." : "Take Snapshot"
                        color: Color.bar.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    enabled: !root.isRestoring && !root.isSnapshotting
                    onContainsMouseChanged: parent.color = containsMouse ? root.selectedBg : root.hoverBg
                    onClicked: root.doSnapshot()
                }
            }

            PanelSectionHeader { text: "Profiles" }

            Column {
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.profiles

                    delegate: Rectangle {
                        id: profileRow
                        readonly property color restFill: Qt.darker(Color.bar.background, 1.05)

                        width: parent.width
                        height: 36
                        radius: Style.cornerRadius
                        color: restFill

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 6

                            Text {
                                text: root.profileIconFor(modelData)
                                color: Qt.darker(Color.bar.text, 1.4)
                                font.pixelSize: 13
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Text {
                                text: modelData
                                color: Color.bar.text
                                font.family: Style.font.family
                                font.pixelSize: Style.font.body
                                Layout.alignment: Qt.AlignVCenter
                                Layout.fillWidth: true
                                elide: Text.ElideRight

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    hoverEnabled: true
                                    enabled: !root.isRestoring && !root.isSnapshotting
                                    onContainsMouseChanged: profileRow.color = containsMouse ? root.hoverBg : profileRow.restFill
                                    onClicked: root.doRestore(modelData)
                                }
                            }

                            Text {
                                text: "󰆴"
                                color: Qt.darker(Color.bar.text, 1.4)
                                font.pixelSize: 13
                                Layout.alignment: Qt.AlignVCenter

                                // Referenced by id, not by walking the parent chain: the
                                // chain here is MouseArea -> Text -> RowLayout, and
                                // RowLayout has no `color` property to assign to.
                                MouseArea {
                                    id: deleteHotspot
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    hoverEnabled: true
                                    enabled: !root.isRestoring && !root.isSnapshotting
                                    onContainsMouseChanged: profileRow.color = containsMouse ? root.deleteBg : profileRow.restFill
                                    onClicked: root.doDelete(modelData)
                                }
                            }
                        }
                    }
                }
            }

            Item { width: 1; height: 4 }

            Text {
                text: root.lastAction
                color: Qt.darker(Color.bar.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.italic: true
                visible: root.lastAction !== ""
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // --- Name Input View ---

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10
            visible: root.showingNameInput

            PanelHero {
                title: "Save Snapshot"
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Qt.darker(Color.bar.text, 1.15)
            }

            TextField {
                id: saveNameField
                width: parent.width
                height: 36
                placeholderText: "Profile name"
                color: Color.bar.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                leftPadding: 10
                background: Rectangle {
                    color: Qt.darker(Color.bar.background, 1.08)
                    radius: Style.cornerRadius
                    border.color: Qt.darker(Color.bar.text, 1.15)
                    border.width: 1
                }
                Keys.onReturnPressed: confirmSave()
                Keys.onEnterPressed: confirmSave()
            }

            Rectangle {
                id: saveButton
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: root.hoverBg

                Text {
                    anchors.centerIn: parent
                    text: "  Save"
                    color: Color.bar.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    // Referenced by id: the parent chain here is
                    // MouseArea -> Rectangle -> Column, and Column has no
                    // `color` property, so `parent.parent.color` threw.
                    onContainsMouseChanged: saveButton.color = containsMouse ? root.selectedBg : root.hoverBg
                    onClicked: confirmSave()
                }
            }

            Rectangle {
                id: cancelButton
                readonly property color restFill: Qt.darker(Color.bar.background, 1.05)

                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: restFill

                Text {
                    anchors.centerIn: parent
                    text: "Cancel"
                    color: Qt.darker(Color.bar.text, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    // See saveButton: assigning to the enclosing Column's
                    // `color` threw a TypeError on every hover.
                    onContainsMouseChanged: cancelButton.color = containsMouse ? Qt.darker(Color.bar.text, 1.1) : cancelButton.restFill
                    onClicked: {
                        root.showingNameInput = false
                        root.pendingSnapshot = null
                        root.lastAction = "Snapshot discarded"
                    }
                }
            }
        }
    }

    // --- Profile Listing ---

    function refreshProfiles() {
        listProc.command = ["python3", root.storeScript, "list", root.profileDir]
        listProc.running = true
    }

    Process {
        id: listProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // The helper emits bare validated names (one per line, capped
                // at 256), so no path parsing or shell is involved.
                var lines = text.trim().split("\n").filter(s => s.length > 0)
                root.profiles = lines
            }
        }
    }

    // --- Snapshot ---

    function doSnapshot() {
        // Guard against re-entrancy: a second snapshot while the async capture
        // chain is in flight would interleave state and corrupt the result.
        if (root.isSnapshotting) return
        root.isSnapshotting = true
        root.lastAction = "Capturing..."
        root._monitorsCaptured = []
        // Arm the watchdog: if any capture stage never completes (a hung
        // capture_tabs.py, a killed hyprctl), failSnapshot() resets the flag
        // so the widget can never latch into a permanent "Capturing...".
        snapshotWatchdog.restart()
        snapClientsProc.running = true
    }

    // Single place that tears down a snapshot attempt. Every capture stage's
    // failure path funnels through here (and the watchdog does too), so
    // `isSnapshotting` is always cleared exactly once and the widget never
    // ends up stuck with the action buttons permanently disabled.
    function failSnapshot(reason) {
        snapshotWatchdog.stop()
        root.isSnapshotting = false
        root.lastAction = reason || "Snapshot failed"
    }

    // 45s is far beyond the worst legitimate chain (hyprctl + /proc reads +
    // per-browser capture, each internally bounded to seconds), so tripping it
    // means something is genuinely stuck rather than merely slow.
    Timer {
        id: snapshotWatchdog
        interval: 45000
        repeat: false
        onTriggered: {
            console.error("WSRESTORE snapshot watchdog fired; killing capture stages")
            snapClientsProc.running = false
            snapCmdlinesProc.running = false
            snapMonitorsProc.running = false
            snapTabsProc.running = false
            root.failSnapshot("Capture timed out")
            root.notify("Capture timed out", "The snapshot was abandoned after 45s")
        }
    }

    Process {
        id: snapClientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var clients = JSON.parse(text)
                    var pids = []
                    var seen = {}
                    for (var p = 0; p < clients.length; p++) {
                        if (!seen[clients[p].pid]) {
                            seen[clients[p].pid] = true
                            pids.push(clients[p].pid)
                        }
                    }
                    snapCmdlinesProc._clients = clients
                    // Robust per-PID capture. Each PID emits one line of
                    // "PID<TAB>cmdline<TAB>cwd". Fields are matched BY PID (not
                    // by array index), so a failed /proc read can never shift
                    // other windows' data (the old plain-text approach slid on
                    // any /proc failure). Tabs/newlines inside values are
                    // collapsed to spaces to keep the TSV format stable.
                    snapCmdlinesProc.command = ["bash", "-lc",
                        "pids=\"" + pids.join(" ") + "\"; " +
                        "for p in $pids; do " +
                        "  cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\\0' ' ' | tr '\\t\\n' '  ' | sed 's/ *$//'); " +
                        "  cwd=$(readlink /proc/$p/cwd 2>/dev/null | tr '\\t\\n' '  '); " +
                        "  printf '%s\\t%s\\t%s\\n' \"$p\" \"$cmd\" \"$cwd\"; " +
                        "done"]
                    snapCmdlinesProc.running = true
                } catch(e) {
                    root.failSnapshot("Failed to capture windows")
                }
            }
        }
    }

    Process {
        id: snapCmdlinesProc
        property var _clients: null
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var clients = snapCmdlinesProc._clients
                // _clients is null only if the previous stage bailed out before
                // setting it. Bail here rather than letting the catch block
                // dereference a null `clients` and throw a second time, which
                // would strand isSnapshotting = true with no way back.
                if (!clients) {
                    root.failSnapshot("Failed to capture windows")
                    return
                }
                try {
                    var infoMap = {}
                    var lines = (text || "").split("\n")
                    for (var l = 0; l < lines.length; l++) {
                        var line = lines[l].trim()
                        if (!line) continue
                        var parts = line.split("\t")
                        if (parts.length >= 1) {
                            var rec = { pid: parts[0], cmdline: parts[1] || "", cwd: parts[2] || "" }
                            infoMap[rec.pid] = rec
                        }
                    }
                    for (var i = 0; i < clients.length; i++) {
                        var info = infoMap[String(clients[i].pid)]
                        clients[i]._cmdline = (info && info.cmdline) ? info.cmdline.trim() : null
                        clients[i]._cwd = (info && info.cwd) ? info.cwd.trim() : null
                    }
                } catch(e) {
                    // A single unparsable line must not lose every window's
                    // /proc data - null the two fields and carry on.
                    for (var k = 0; k < clients.length; k++) {
                        clients[k]._cmdline = null
                        clients[k]._cwd = null
                    }
                }
                snapMonitorsProc._clients = clients
                snapMonitorsProc.running = true
            }
        }
    }

    Process {
        id: snapMonitorsProc
        property var _clients: null
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var monitors = JSON.parse(text)
                    var clients = snapMonitorsProc._clients

                    var monMap = {}
                    for (var m = 0; m < monitors.length; m++) {
                        monMap[monitors[m].id] = monitors[m].name
                    }

                    var windows = []

                    // Clean a captured /proc cmdline into a safe relaunch string:
                    // collapses internal whitespace (single spaces) and trims.
                    function cleanCmd(raw) {
                        if (!raw) return null
                        var v = raw.replace(/\s+/g, " ").trim()
                        return v.length ? v : null
                    }

                    // Command cache per PID. Multiple split-screen windows from
                    // one process (e.g. two nautilus windows sharing a PID)
                    // must ALL get the same launch command - otherwise a later
                    // window falls back to className, which can't reopen it.
                    // For single-instance apps the captured cmdline already
                    // carries the right flag (e.g. "nautilus --new-window").
                    var pidCmd = {}

                    for (var i = 0; i < clients.length; i++) {
                        var c = clients[i]
                        var monName = monMap[c.monitor] || String(c.monitor)

                        var cmd = pidCmd[c.pid]
                        if (cmd === undefined) {
                            cmd = cleanCmd(c._cmdline)
                            pidCmd[c.pid] = cmd === null ? null : cmd
                        }

                        // Browser detection: mark the window so the tab-capture
                        // pass (snapTabsProc) can enrich it later, and resolve
                        // the profile/user-data dir from the command line. This
                        // is done here (per window) so tabs are attached to the
                        // right window and restore can reopen them in place.
                        var btype = root.browserTypeForClass(c.class)
                        var bprofile = btype ? root.resolveBrowserProfile(btype, c._cmdline) : null

                        windows.push({
                            "class": c.class,
                            "title": c.title,
                            "pid": c.pid,
                            "address": c.address,
                            "workspace": c.workspace.name,
                            "workspaceId": c.workspace.id,
                            "monitor": monName,
                            "monitorId": c.monitor,
                            "command": cmd,
                            "cwd": c._cwd ? c._cwd.trim() : null,
                            "position": [c.at[0], c.at[1]],
                            "size": [c.size[0], c.size[1]],
                            "splitRatio": c.splitratio,
                            "floating": c.floating,
                            "fullscreen": c.fullscreen,
                            "browser": btype,
                            "browserProfile": bprofile,
                            "tabs": null
                        })
                    }
                    snapTabsProc._windows = windows
                    root._monitorsCaptured = monitors
                    snapTabsProc.begin()
                } catch(e) {
                    console.error("WSRESTORE snapMonitors error:", String(e && e.stack || e))
                    root.failSnapshot("Failed to capture monitors")
                }
            }
        }
    }

    // Tab-capture pass. After windows are assembled, run the per-browser
    // tab capture (Firefox session file / Chromium CDP; see scripts/capture_tabs.py)
    // for each unique browser profile, then finalize pendingSnapshot. Tabs are
    // attached to the first window of each profile so restore won't reopen the
    // same pages from multiple windows sharing one browser process.
    Process {
        id: snapTabsProc
        property var _windows: []
        property var _results: {}

        // Build and run the capture for every unique browser profile.
        function begin() {
            snapTabsProc.command = []
            snapTabsProc._results = {}
            var windows = snapTabsProc._windows
            var script = Qt.resolvedUrl("scripts/capture_tabs.py").toString().replace(/^file:\/\//, "")
            var seen = {}
            var invocations = []
            for (var i = 0; i < windows.length; i++) {
                var w = windows[i]
                if (!w.browser || !w.browserProfile) continue
                var key = w.browser + "\u0001" + w.browserProfile
                if (seen[key]) continue
                seen[key] = true
                invocations.push("python3 " + root.shellArg(script) + " " +
                    root.shellArg(w.browser) + " " + root.shellArg(w.browserProfile) + " " +
                    root.shellArg(key))
            }
            if (invocations.length === 0) {
                snapTabsProc.finishNow()
                return
            }
            snapTabsProc.command = ["bash", "-lc", invocations.join("; ")]
            snapTabsProc.running = true
        }

        function finishNow() {
            // try/catch is load-bearing here: without it a throw from assemble()
            // (or from the name field) skipped `isSnapshotting = false` and left
            // the widget permanently stuck on "Capturing..." with every action
            // disabled - recoverable only by restarting the shell.
            try {
                root.pendingSnapshot = snapTabsProc.assemble()
                snapshotWatchdog.stop()
                root.isSnapshotting = false
                root.lastAction = "Captured " + snapTabsProc._windows.length + " windows"
                saveNameField.text = generateDefaultName()
                root.showingNameInput = true
            } catch(e) {
                console.error("WSRESTORE assemble error:", String(e && e.stack || e))
                root.pendingSnapshot = null
                root.failSnapshot("Failed to assemble snapshot")
            }
        }

        // Build pendingSnapshot, attaching parsed tab data onto windows.
        function assemble() {
            var windows = snapTabsProc._windows
            var results = snapTabsProc._results || {}
            var attached = {}
            for (var i = 0; i < windows.length; i++) {
                var w = windows[i]
                if (!w.browser || !w.browserProfile) continue
                var key = w.browser + "\u0001" + w.browserProfile
                if (attached[key]) continue
                attached[key] = true
                var res = results[key]
                if (res && res.ok && Array.isArray(res.tabs)) {
                    w.tabs = res.tabs
                } else {
                    w.tabs = []
                }
            }
            return {
                "timestamp": Date.now(),
                "windows": windows,
                "monitors": root._monitorsCaptured || []
            }
        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // Each line is one JSON object from the helper, routed by its
                // embedded _profile key (set by the capture script).
                var results = {}
                var linesOut = (text || "").split("\n")
                for (var r = 0; r < linesOut.length; r++) {
                    var ln = linesOut[r].trim()
                    if (!ln) continue
                    try {
                        var o = JSON.parse(ln)
                        if (o && o._profile) results[o._profile] = o
                    } catch(e) {}
                }
                // Snapshot the monitors from the last stage (stored on root).
                snapTabsProc._results = results
                snapTabsProc.finishNow()
            }
        }
    }

    // --- Save ---

    function doSave(name) {
        if (!root.pendingSnapshot || name.length === 0) return
        var safe = root.sanitizeProfileName(name)
        if (safe === null) {
            root.lastAction = "Invalid profile name"
            return
        }
        var json = JSON.stringify(root.pendingSnapshot, null, 2)
        // The store helper reads the JSON from stdin (never a temp file or a
        // shell heredoc). payload size is bounded by the helper; enforcement
        // of cardinality happens both here and inside the helper.
        if (root.enforceProfileCardinality(root.pendingSnapshot) === null) {
            root.lastAction = "Snapshot exceeded limits"
            return
        }
        saveProc._json = json
        saveProc.stdinEnabled = true
        saveProc.command = ["python3", root.storeScript, "save", root.profileDir, safe]
        saveProc.running = true
    }

    Process {
        id: saveProc
        property string _json: ""
        command: []
        stdinEnabled: true
        // NOTE on payload size: a snapshot with browser tabs serialises to far
        // more than the 64 KiB pipe buffer (measured: 6 windows x 250 tabs =
        // 221 KB), so this was probed rather than assumed. Quickshell buffers
        // the overflow internally - a real 221 KB save through this exact path
        // lands on disk whole and parses as valid JSON - so a single write()
        // followed by closing stdin is correct and must NOT be converted into a
        // byte-counting write loop. Process.write() returns void and there is no
        // writeReturned signal (checked against quickshell 0.2.1 and 0.3.1), so
        // such a loop could not even be written.
        onStarted: {
            saveProc.write(saveProc._json)
            saveProc.stdinEnabled = false
        }
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                // Keep pendingSnapshot so the user can retry; never report success.
                root.lastAction = "Failed to save profile"
                root.notify("Failed to save", "Could not write profile file")
                return
            }
            root.lastAction = "Profile saved"
            root.pendingSnapshot = null
            root.showingNameInput = false
            root.refreshProfiles()
            root.notify("Snapshot saved", saveNameField.text)
        }
    }

    // --- Restore ---

    function doRestore(name) {
        if (root.isRestoring) return
        var safe = root.sanitizeProfileName(name)
        if (safe === null) {
            root.isRestoring = false
            root.lastAction = "Invalid profile name"
            return
        }
        root.isRestoring = true
        root.lastAction = "Restoring..."
        restoreProc.command = ["python3", root.storeScript, "load", root.profileDir, safe]
        restoreProc.running = true
    }

    Process {
        id: restoreProc
        command: []
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    // Loading runs through the store helper, which revalidates
                    // the JSON and its cardinality (bounded, no-follow read) —
                    // here we additionally enforce the same caps before any
                    // launch command is generated from the content.
                    var profile = JSON.parse(text)
                    if (root.enforceProfileCardinality(profile) === null) {
                        root.isRestoring = false
                        root.lastAction = "Failed to load profile"
                        return
                    }
                    restoreWithConflicts(profile)
                } catch(e) {
                    root.isRestoring = false
                    root.lastAction = "Failed to load profile"
                }
            }
        }
    }

    function restoreWithConflicts(profile) {
        if (!profile || !profile.windows || profile.windows.length === 0) {
            root.isRestoring = false
            root.lastAction = "Profile is empty"
            return
        }
        checkExistingProc._profile = profile
        checkExistingProc.running = true
    }

    Process {
        id: checkExistingProc
        property var _profile: null
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var existing = []
                try {
                    existing = JSON.parse(text)
                } catch(e) {
                    existing = []
                }
                root.buildAndRunRestore(checkExistingProc._profile, existing)
            }
        }
    }

    Process {
        id: masterRestoreProc
        property int _count: 0
        property int _failed: 0
        property bool _reported: false

        // Reports the outcome exactly once. Prefers the failure count carried
        // on stdout (WSR_FAILED=) over the bare exit code, because every step
        // in the script is individually guarded, so the exit code alone cannot
        // distinguish "all good" from "every dispatch was rejected".
        function report(exitCode) {
            if (_reported) return
            _reported = true
            root.isRestoring = false

            if (exitCode !== 0) {
                root.lastAction = "Restore failed"
                root.notify("Restore failed", "See " + root.restoreLogPath)
                return
            }

            if (_failed > 0) {
                // Partial failure. Never claim a clean restore when dispatches
                // were rejected - the old code always said "Restored N".
                root.lastAction = "Restored " + Math.max(0, _count - _failed) + "/" + _count + " windows"
                root.notify("Restore partially failed",
                            _failed + " step(s) failed - see " + root.restoreLogPath)
                return
            }

            root.lastAction = "Restored " + _count + " windows"
            root.notify("Workspace restored", _count + " windows launched")
        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // The launcher echoes the persisted failure count on its last
                // stdout line; parse it so the summary is truthful.
                var lines = (text || "").split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var m = /^WSR_FAILED=(\d+)\s*$/.exec(lines[i].trim())
                    if (m) masterRestoreProc._failed = parseInt(m[1], 10)
                }
            }
        }

        onExited: function(exitCode) {
            // Give the collector a chance to deliver the final stdout line
            // before deciding, then report once.
            Qt.callLater(function() { masterRestoreProc.report(exitCode) })
        }
    }

    // Path the restore script copies its diagnostics to, so a failed restore is
    // inspectable after the private WSROOT is torn down.
    readonly property string restoreLogPath: root.profileDir + "/last-restore.log"

    // Build and run the restore script. Extracted into its own function so the
    // whole construction is wrapped in try/catch: any unexpected throw here
    // must reset isRestoring, or the widget stays stuck in "Restoring..."
    // forever with no way to recover except restarting the shell.
    function buildAndRunRestore(profile, existing) {
        try {
            var lines = ["#!/bin/bash"]
            // WSROOT is exported by the outer launcher (a private mktemp -d).
            // Everything this restore writes - log, launch scripts, safety
            // script - lives inside it, never in shared /tmp. The private dir
            // is removed on exit unless the detached safety pass owns cleanup.
            lines.push("LOGFILE=\"$WSROOT/restore.log\"")
            lines.push("SAFETY_OWNED=0")
            lines.push("STATUS=\"$WSROOT/status\"")
            lines.push("FAILED=0")
            // note_fail is defined before any step that can call it, and
            // replaces the bare `|| true` swallow so a failed dispatch is
            // counted instead of silently ignored.
            lines.push("note_fail() { FAILED=$((FAILED+1)); echo \"[fail] $1\" >> \"$LOGFILE\"; }")
            lines.push("printf '0' > \"$STATUS\"")
            // The script does NOT delete $WSROOT itself: the outer launcher has
            // to read $WSROOT/status and $WSROOT/restore.log after this exits,
            // and a cleanup trap here would destroy that evidence first. The
            // launcher copies the diagnostics out and then removes the dir.
            // (When a safety pass owns the dir, the launcher's remove is a
            // no-op because the pass has already finished with it.)
            lines.push("trap 'printf \"%s\" \"$FAILED\" > \"$STATUS\" 2>/dev/null || true' EXIT")
            lines.push("echo \"[start] wsroot=$WSROOT profile_windows=" + profile.windows.length + " existing=" + (existing ? existing.length : 0) + "\" >> \"$LOGFILE\"")

            // Track which profile windows have been matched
            var matched = []
            for (var p = 0; p < profile.windows.length; p++) matched[p] = false

            var toMove = []
            var toFloat = []
            var matchedAddrs = []
            // Addresses of currently-open browser windows whose snapshot had
            // captured tabs. These are closed (so the browser process quits)
            // before we relaunch it fresh with exactly the snapshot's tabs.
            // This avoids running-browser CLI quirks (Firefox one-window-per-URL,
            // Vivaldi session-restore extras) and workspace-focus slippage.
            var browserCloseAddrs = []

            if (existing && existing.length > 0) {
                for (var i = 0; i < existing.length; i++) {
                    var e = existing[i]

                    // Matching by class then title lives in the shared library, so
                    // it is covered by test/restoreLogic.test.mjs - including the
                    // case-insensitive comparison this path depends on, and the
                    // "skip windows already claimed" rule that keeps repeated
                    // scans from clobbering the pick with the last same-class
                    // window.
                    var bestIdx = Logic.matchProfileWindow(e, profile.windows, matched)

                    if (bestIdx >= 0) {
                        var target = profile.windows[bestIdx]
                        // Browser snapshot windows with captured tabs are
                        // relaunched fresh: close the existing matching window so
                        // the browser process exits, then let Phase 3 spawn one
                        // clean window with exactly the snapshot's tabs. Leave
                        // matched[] false so Phase 3 spawns this window.
                        if (target.browser && target.tabs && target.tabs.length > 0) {
                            // Carry the PID so Phase 2c can wait for the actual
                            // process to exit instead of guessing with a fixed
                            // sleep - a browser that outlives the sleep would
                            // swallow the relaunch as a forwarded command.
                            browserCloseAddrs.push({ addr: e.address, pid: e.pid })
                            continue
                        }
                        matched[bestIdx] = true
                        matchedAddrs.push(e.address)
                        var tws = root.safeWorkspace(target.workspace)
                        // Move to correct workspace if needed
                        if (tws !== null && String(e.workspace.name) !== String(target.workspace)) {
                            toMove.push({addr: e.address, ws: tws, cls: e.class, splitRatio: target.splitRatio, fullscreen: target.fullscreen, e_floating: e.floating, e_fullscreen: e.fullscreen})
                        }
                        // Restore floating state and position only if it differs
                        // from the window's current state, so "toggle" never
                        // leaves an already-floating window de-floated.
                        if (target.floating) {
                            toFloat.push({addr: e.address, pos: target.position, size: target.size, e_floating: e.floating, e_fullscreen: e.fullscreen})
                        }
                    } else {
                        // Unmatched existing window: left untouched (we no
                        // longer SIGKILL unmatched windows).
                    }
                }
            }

            // Phase 0: Pin every snapshotted workspace to the monitor it
            // was on at capture time. Do this BEFORE anything moves into
            // those workspaces - Hyprland workspaces are global, not
            // monitor-scoped, so a workspace not yet anchored to a monitor
            // gets claimed by whichever monitor is focused when the first
            // window lands in it (multi-monitor setups).
            var wsToMonitor = {}
            for (var wm = 0; wm < profile.windows.length; wm++) {
                var pws = root.safeWorkspace(profile.windows[wm].workspace)
                var pmon = profile.windows[wm].monitor
                if (pws !== null && pmon && /^[A-Za-z0-9-]{1,64}$/.test(pmon)) {
                    wsToMonitor[pws] = pmon
                }
            }
            for (var wsName in wsToMonitor) {
                if (!wsToMonitor[wsName]) continue
                lines.push("echo \"[pin] ws=" + wsName + " monitor=" + wsToMonitor[wsName] + "\" >> \"$LOGFILE\"")
                lines.push("hyprctl dispatch \"hl.dsp.workspace.move({workspace='" + wsName + "', monitor='" + wsToMonitor[wsName] + "'})\" >>\"$LOGFILE\" 2>&1 || note_fail \"pin ws=" + wsName + "\"")
            }

            // Phase 1: Removed. We no longer SIGKILL unmatched windows and
            // no longer delete browser session caches - both were
            // destructive and could be driven by a crafted profile. Restore
            // now only moves matched windows and spawns missing ones.

            // Phase 2: Move matched windows to correct workspaces
            for (var m = 0; m < toMove.length; m++) {
                var mv = toMove[m]
                lines.push("echo \"[move-existing] ws=" + mv.ws + " addr=" + mv.addr + "\" >> \"$LOGFILE\"")
                lines.push("hyprctl dispatch \"hl.dsp.window.move({workspace='" + mv.ws + "', window='address:" + mv.addr + "', follow=false})\" >>\"$LOGFILE\" 2>&1 || note_fail \"move ws=" + mv.ws + " addr=" + mv.addr + "\"")
                // Restore fullscreen only if the target was captured fullscreen
                // AND the existing window isn't already fullscreen (avoids
                // leaving the user stuck in fullscreen unexpectedly).
                if (mv.fullscreen && !mv.e_fullscreen) {
                    lines.push("hyprctl dispatch \"hl.dsp.window.fullscreen({mode='fullscreen', window='address:" + mv.addr + "'})\" >>\"$LOGFILE\" 2>&1 || note_fail \"fullscreen addr=" + mv.addr + "\"")
                }
            }

            // Phase 2b: Apply floating state and positioning
            for (var f = 0; f < toFloat.length; f++) {
                var fl = toFloat[f]
                var fx = root.numOr(fl.pos[0])
                var fy = root.numOr(fl.pos[1])
                var fw = root.numOr(fl.size[0])
                var fh = root.numOr(fl.size[1])
                // Only toggle floating when the window's current state differs
                // from the target's captured state, so an already-floating
                // window is not un-floated.
                if (!fl.e_floating) {
                    lines.push("hyprctl dispatch \"hl.dsp.window.float({action='toggle', window='address:" + fl.addr + "'})\" >>\"$LOGFILE\" 2>&1 || note_fail \"float addr=" + fl.addr + "\"")
                }
                lines.push("hyprctl dispatch \"hl.dsp.window.move({x=" + fx + ", y=" + fy + ", relative=false, window='address:" + fl.addr + "'})\" >>\"$LOGFILE\" 2>&1 || note_fail \"float-move addr=" + fl.addr + "\"")
                lines.push("hyprctl dispatch \"hl.dsp.window.resize({x=" + fw + ", y=" + fh + ", window='address:" + fl.addr + "'})\" >>\"$LOGFILE\" 2>&1 || note_fail \"float-resize addr=" + fl.addr + "\"")
            }

            // Phase 2c: Close existing browser windows whose snapshot carried
            // captured tabs. Closing them makes the browser process exit; the
            // relaunch in Phase 3 then starts it fresh so `browser url1 url2`
            // opens exactly one window with the snapshot's tabs. Wait for the
            // process to actually exit so the fresh launch isn't forwarded to
            // the dying instance.
            if (browserCloseAddrs.length > 0) {
                for (var bc = 0; bc < browserCloseAddrs.length; bc++) {
                    var bEntry = browserCloseAddrs[bc]
                    lines.push("echo \"[close-browser] addr=" + bEntry.addr + "\" >> \"$LOGFILE\"")
                    lines.push("hyprctl dispatch \"hl.dsp.window.close({window='address:" + bEntry.addr + "'})\" >>\"$LOGFILE\" 2>&1 || note_fail \"close-browser addr=" + bEntry.addr + "\"")
                    // Poll for exit (up to ~10s) rather than sleeping a fixed
                    // 1.5s: a cold-quitting browser that outlives the sleep
                    // would receive the relaunch as a command-line message and
                    // the snapshot's tabs would never open. `kill -0` on a
                    // reaped-but-not-waited PID still succeeds, so fall back to
                    // a bounded overall wait if the PID never disappears.
                    if (bEntry.pid !== undefined && bEntry.pid !== null && isFinite(Number(bEntry.pid)) && Number(bEntry.pid) > 0) {
                        var pidNum = Math.round(Number(bEntry.pid))
                        lines.push("for _i in $(seq 1 40); do kill -0 " + pidNum + " 2>/dev/null || break; sleep 0.25; done")
                    } else {
                        lines.push("sleep 1.5")
                    }
                }
            }

            // Phase 3: Spawn missing windows directly onto their target
            // workspace. Strategy: focus the target workspace FIRST, then
            // launch - so each window opens where it belongs instead of
            // piling onto the currently focused workspace and relying on a
            // fragile later move. This is far more reliable for both
            // single and duplicate-class windows.
            var spawnCount = 0
            var spawnTargets = []
            for (var j = 0; j < profile.windows.length; j++) {
                if (!matched[j]) {
                    var w = profile.windows[j]
                    var ws = root.safeWorkspace(w.workspace)
                    var cls = root.safeClass(w.class)
                    if (ws === null || cls === null) {
                        // Ignore entries whose metadata can't be represented
                        // safely rather than risk injection in generated code.
                        lines.push("echo \"[launch] skipped unsafe metadata\" >> \"$LOGFILE\"")
                        continue
                    }
                    var cmd = root.sanitizeLaunchCommand(w.command, cls)

                    // For browser windows with captured tabs, append the page
                    // For browser windows with captured tabs, produce the launch
                    // commands (which may be several, e.g. Firefox opens a single
                    // new window then adds tabs) that reopen the pages in place.
                    var cmds
                    if (w.browser && (w.tabs && w.tabs.length > 0)) {
                        cmds = root.buildBrowserLaunchCommands(cmd, cls, w.tabs)
                    } else {
                        cmds = cmd.length > 0 ? [cmd] : []
                    }

                    // Launch file: one (already shell-quoted) exec line per step.
                    if (cmds.length === 0) {
                        lines.push("echo \"[launch] no safe command for ws=" + ws + "\" >> \"$LOGFILE\"")
                    }
                    var steps = []
                    for (var k = 0; k < cmds.length; k++) {
                        if (k === 0 && cmds.length === 1) {
                            steps.push("exec " + cmds[k])
                        } else if (k === 0) {
                            steps.push(cmds[k] + " &")
                        } else {
                            steps.push(cmds[k])
                        }
                        if (k < cmds.length - 1) steps.push("sleep 0.4")
                    }
                    var launchline = steps.length > 0 ? steps.join("\n") : "exit 1"
                    lines.push("SPATH=\"$WSROOT/spawn-" + j + ".sh\"")
                    lines.push("printf '#!/bin/bash\\n%s\\n' " + root.shellArg(launchline) + " > \"$SPATH\" && chmod 700 \"$SPATH\"")
                    // Focus the target workspace so the window lands on it
                    lines.push("hyprctl dispatch \"hl.dsp.focus({workspace='" + ws + "'})\" >>\"$LOGFILE\" 2>&1 || note_fail \"focus ws=" + ws + "\"")
                    lines.push("sleep 0.3")
                    lines.push("bash \"$SPATH\" &")
                    lines.push("echo \"[launch] ws=" + ws + " cmd='$SPATH'\" >> \"$LOGFILE\"")

                    // Track for a class-based safety re-check pass
                    spawnTargets.push({
                        cls: cls,
                        ws: ws,
                        floating: w.floating,
                        fullscreen: w.fullscreen,
                        splitRatio: w.splitRatio,
                        pos: w.position,
                        size: w.size
                    })
                    spawnCount++
                }
            }

            // Phase 3b: Safety re-check pass. Launches in Phase 3 already
            // place windows on the correct workspace via focus-then-launch,
            // so this is only a background safety net for the rare app that
            // ignores the focused workspace. It polls by CLASS (fork-stable)
            // for up to ~15s per target. It MUST run detached: the restore
            // notification fires when the main script exits, and we don't
            // want the notification blocked behind this polling.
            // Exclude pre-existing matched windows via MATCHED_ADDRS
            if (spawnCount > 0) {
                var safety = []
                safety.push("#!/bin/bash")
                safety.push("LOGFILE=\"$WSROOT/restore.log\"")
                // The safety pass is the last consumer of the private WSROOT,
                // so it owns final cleanup - via a trap, so it runs AFTER the
                // polling loop below has finished using $WSROOT. Before
                // removing it, copy the diagnostics out to the profile dir so a
                // partial/failed restore stays inspectable (the outer launcher
                // does the same, but it may run while this pass is mid-flight).
                safety.push("cleanup_safety() {")
                safety.push("  if [ -n \"$WSPROFILES\" ] && [ -d \"$WSPROFILES\" ]; then")
                safety.push("    cp \"$WSROOT/restore.log\" \"$WSPROFILES/last-restore.log\" 2>/dev/null || true")
                safety.push("    [ -f \"$WSROOT/status\" ] && cp \"$WSROOT/status\" \"$WSPROFILES/last-restore-status\" 2>/dev/null || true")
                safety.push("  fi")
                safety.push("  rm -rf \"$WSROOT\"")
                safety.push("}")
                safety.push("trap cleanup_safety EXIT")
                safety.push("MATCHED_ADDRS=\"" + matchedAddrs.join(" ") + "\"")
                safety.push("sleep 1")
                safety.push("MOVED_ADDRS=\"\"")
                for (var s = 0; s < spawnTargets.length; s++) {
                    var t = spawnTargets[s]
                    var jqFilter = '.[] | select((.class | ascii_downcase | gsub("\\\\.desktop$"; "")) == "' + t.cls + '") | [.address, .workspace.name] | @tsv'
                    // Up to ~15s of polling (30 attempts x 0.5s) - electron
                    // apps (Slack, VS Code, Discord) routinely take longer
                    // than a short budget to register their window.
                    safety.push("ATTEMPT=0")
                    safety.push("HANDLED=0")
                    safety.push("while [ $ATTEMPT -lt 30 ] && [ $HANDLED -eq 0 ]; do")
                    safety.push("  MATCHES=$(hyprctl clients -j | jq -r '" + jqFilter + "' 2>>\"$LOGFILE\")")
                    safety.push("  echo \"[move-spawn] attempt=$ATTEMPT cls=" + t.cls + " ws=" + t.ws + " matches=$MATCHES\" >> \"$LOGFILE\"")
                    safety.push("  while IFS=$'\\t' read -r A W; do")
                    safety.push("    [ -z \"$A\" ] && continue")
                    safety.push("    if [[ \" $MOVED_ADDRS \" == *\" $A \"* ]] || [[ \" $MATCHED_ADDRS \" == *\" $A \"* ]]; then continue; fi")
                    safety.push("    MOVED_ADDRS=\"$MOVED_ADDRS $A\"")
                    safety.push("    if [ \"$W\" != \"" + t.ws + "\" ]; then")
                    safety.push("      hyprctl dispatch \"hl.dsp.window.move({workspace='" + t.ws + "', window='address:$A', follow=false})\" 2>>\"$LOGFILE\" || true")
                    if (t.floating) {
                        var sx = root.numOr(t.pos[0])
                        var sy = root.numOr(t.pos[1])
                        var sw = root.numOr(t.size[0])
                        var sh = root.numOr(t.size[1])
                        safety.push("      hyprctl dispatch \"hl.dsp.window.float({action='toggle', window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                        safety.push("      hyprctl dispatch \"hl.dsp.window.move({x=" + sx + ", y=" + sy + ", relative=false, window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                        safety.push("      hyprctl dispatch \"hl.dsp.window.resize({x=" + sw + ", y=" + sh + ", window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                    }
                    if (t.fullscreen) {
                        safety.push("      hyprctl dispatch \"hl.dsp.window.fullscreen({mode='fullscreen', window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                    }
                    safety.push("    fi")
                    safety.push("    HANDLED=1")
                    safety.push("  done <<< \"$MATCHES\"")
                    safety.push("  ATTEMPT=$((ATTEMPT+1))")
                    safety.push("  if [ $HANDLED -eq 0 ]; then sleep 0.5; fi")
                    safety.push("done")
                }
                // Write and detach the safety pass so it doesn't delay the
                // restore notification. The script and everything it uses
                // live in the private $WSROOT (never shared /tmp). Hand
                // cleanup of $WSROOT over to the safety pass, which removes
                // the private dir when it finishes.
                lines.push("SAFETY_OWNED=1")
                lines.push("SAFETY=\"$WSROOT/safety.sh\"")
                lines.push("printf '%s\\n' " + Util.shellQuote(safety.join("\n")) + " > \"$SAFETY\" && chmod 700 \"$SAFETY\"")
                lines.push("nohup bash \"$SAFETY\" >/dev/null 2>&1 &")
                lines.push("disown")
            }

            // Count DISTINCT windows acted on. toMove and toFloat can name the same
            // address (a floating window that also needs moving), so summing
            // the two array lengths over-reported. Build a set of addresses
            // plus the spawns instead.
            var touchedAddrs = {}
            for (var ti = 0; ti < toMove.length; ti++) touchedAddrs[toMove[ti].addr] = true
            for (var tf = 0; tf < toFloat.length; tf++) touchedAddrs[toFloat[tf].addr] = true
            var totalCount = Object.keys(touchedAddrs).length + spawnCount

            var scriptContent = lines.join("\n")
            masterRestoreProc._count = totalCount
            // Run everything from a private, freshly-created temp directory
            // (mktemp -d, 0700 with umask 077) instead of predictable shared
            // /tmp pathnames. This avoids symlink/clobber and write/execute
            // races on restore.sh, spawn-*.sh, safety.sh and the log. The
            // restore.sh path is never a replaceable shared name, and the
            // safety pass cleans the private dir up when it finishes.
            //
            // After the script finishes, copy the status count and the log out
            // of $WSROOT into the profile dir before it is torn down, then
            // report the real outcome.
            masterRestoreProc.command = ["bash", "-c",
                "set -o pipefail; " +
                "WSROOT=$(mktemp -d) || exit 1; " +
                "chmod 700 \"$WSROOT\" || exit 1; " +
                "umask 077; " +
                "export WSROOT; " +
                "export WSPROFILES=" + root.shellArg(root.profileDir) + "; " +
                "printf '%s\\n' " + Util.shellQuote(scriptContent) + " > \"$WSROOT/restore.sh\" && " +
                "bash \"$WSROOT/restore.sh\"; " +
                "_rc=$?; " +
                "_failed=$(cat \"$WSROOT/status\" 2>/dev/null || echo 0); " +
                "case \"$_failed\" in ''|*[!0-9]*) _failed=0 ;; esac; " +
                "mkdir -p \"$WSPROFILES\" 2>/dev/null || true; " +
                "printf '%s' \"$_failed\" > \"$WSPROFILES/last-restore-status\" 2>/dev/null || true; " +
                "cp \"$WSROOT/restore.log\" \"$WSPROFILES/last-restore.log\" 2>/dev/null || true; " +
                "echo \"WSR_FAILED=$_failed\"; " +
                "rm -rf \"$WSROOT\"; " +
                "exit $_rc"]
            masterRestoreProc._failed = 0
            masterRestoreProc._reported = false
            masterRestoreProc.running = true
        } catch(err) {
            root.isRestoring = false
            root.lastAction = "Restore failed"
            root.notify("Restore failed", "Could not build restore script")
        }
    }

    // --- Delete ---

    // Name awaiting delete confirmation. Held here rather than passed through
    // the dialog so the dialog stays a dumb pair of callbacks.
    property string pendingDeleteName: ""

    // Ask first. A single unconfirmed click on a 22px icon used to destroy a
    // profile irrecoverably.
    function confirmDelete(name) {
        var safe = root.sanitizeProfileName(name)
        if (safe === null) {
            root.lastAction = "Invalid profile name"
            return
        }
        root.pendingDeleteName = safe
        deleteDialog.opened = true
    }

    function doDelete(name) {
        var safe = root.sanitizeProfileName(name)
        if (safe === null) {
            root.lastAction = "Invalid profile name"
            return
        }
        delProc.command = ["python3", root.storeScript, "delete", root.profileDir, safe]
        delProc.running = true
    }

    Process {
        id: delProc
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                root.lastAction = "Failed to delete profile"
                root.notify("Failed to delete", "Could not remove profile file")
                return
            }
            root.lastAction = "Deleted"
            root.cursorIndex = -1
            root.refreshProfiles()
            root.notify("Profile deleted", "")
        }
    }

    function confirmSave() {
        var name = saveNameField.text.trim()
        if (name.length > 0) {
            root.doSave(name)
        }
    }

    // Abandon a capture without saving it. Shared by the Cancel button and by
    // dismissing the panel, so the prompt and its snapshot always die together.
    function discardSnapshot() {
        root.showingNameInput = false
        root.pendingSnapshot = null
        root.lastAction = "Snapshot discarded"
    }

    // The keyboard cursor indexes into `profiles`, so it has to be dropped or
    // clamped whenever that list changes - otherwise deleting the last row
    // leaves the cursor pointing past the end.
    onProfilesChanged: {
        if (root.cursorIndex >= root.profiles.length) root.cursorIndex = -1
    }
}
