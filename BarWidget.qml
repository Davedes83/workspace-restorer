import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root

    moduleName: "davedes.workspace-restorer"
    ipcTarget: "workspace-restorer"

    property var profiles: []
    property bool isSnapshotting: false
    property bool isRestoring: false
    property string lastAction: ""
    property string profileDir: Quickshell.env("HOME") + "/.config/omarchy/workspace-restorer"
    property var pendingSnapshot: null
    property bool showingNameInput: false
    property var monitorMap: ({})

    readonly property color hoverBg: bar
        ? Style.hoverFillFor(bar.foreground, Color.accent)
        : Qt.darker(Color.bar.text, 1.1)
    readonly property color selectedBg: bar
        ? Style.selectedFillFor(bar.foreground, Color.accent)
        : Qt.darker(Color.bar.text, 1.15)

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    Component.onCompleted: {
        refreshProfiles()
        buildMonitorMap()
    }

    function notify(summary, body) {
        Quickshell.execDetached(["notify-send", "-a", "Workspace Restorer", "-i", "preferences-desktop-workspaces", summary, body || ""])
    }

    // Return a valid, safe profile filename (without the .json suffix) or null.
    // Prevents path traversal: rejects separators, "..", leading dots (hidden
    // files), control characters, and overly long names so a crafted profile
    // name can never escape the profile directory on save/read/delete.
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

    // Return <name> if it resolves inside the profile directory, else null.
    // Defense in depth on top of sanitizeProfileName so a corrupted filename
    // can never read/write/delete outside the profile directory.
    function validProfilePath(name) {
        var safe = root.sanitizeProfileName(name)
        if (safe === null) return null
        var base = root.profileDir
        var resolved = base + "/" + safe + ".json"
        // After sanitizing, the only separators are the ones we add, so a
        // simplified containment check is sufficient.
        if (resolved.indexOf(base) !== 0) return null
        return resolved
    }

    // Shell-quote a string so a crafted value used in generated shell code
    // cannot break out into a new command. Use for ALL profile/window-derived
    // values injected into restore commands.
    function shellArg(s) {
        if (s === null || s === undefined) return "''"
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // Build a safe relaunch command line from an editable profile "command".
    // The executable token is restricted to a plain path/name (no shell
    // metacharacters) and every token is shell-quoted, so a crafted profile
    // cannot smuggle in $(...), backticks, ;, |, redirections, etc. Returns a
    // ready-to-execute command string, or "" if nothing usable.
    function sanitizeLaunchCommand(raw, fallbackClass) {
        var src = raw || (fallbackClass ? fallbackClass.toLowerCase() : "")
        var tokens = String(src).split(/\s+/).filter(function(t) { return t.length > 0 })
        if (tokens.length === 0) return ""
        // First token is the executable: must be a plain name or ./-relative path.
        if (!/^(\.?\/)?[A-Za-z0-9_][A-Za-z0-9_.+/-]*$/.test(tokens[0])) return ""
        var out = []
        for (var i = 0; i < tokens.length; i++) out.push(root.shellArg(tokens[i]))
        return out.join(" ")
    }

    // Validate a workspace name from editable metadata. Real workspaces are
    // short strings of digits (optionally with a name/label), so only accept
    // a conservative safe set to keep it from injecting shell/jq.
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

    // Coerce an editable coordinate/size value to a finite number so it can
    // never smuggle shell metacharacters into a generated dispatch.
    function numOr(v) {
        var n = Number(v)
        return isFinite(n) ? Math.round(n) : 0
    }

    // Pick a Nerd Font glyph that fits a profile name, falling back to a
    // generic icon when no keyword matches.
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

    function generateDefaultName() {
        var d = new Date()
        var pad = function(n) { return n < 10 ? "0" + n : "" + n }
        return "snapshot-" + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
               "-" + pad(d.getHours()) + pad(d.getMinutes())
    }

    function buildMonitorMap() {
        monitorMapProc.running = true
    }

    Process {
        id: monitorMapProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var monitors = JSON.parse(text)
                    var map = {}
                    for (var i = 0; i < monitors.length; i++) {
                        map[monitors[i].id] = monitors[i].name
                    }
                    root.monitorMap = map
                } catch(e) {}
            }
        }
    }

    function resolveExe(className) {
        return className.toLowerCase()
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
                        width: parent.width
                        height: 36
                        radius: Style.cornerRadius
                        color: Qt.darker(Color.bar.background, 1.05)

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
                                    onContainsMouseChanged: parent.parent.parent.color = containsMouse ? root.hoverBg : Qt.darker(Color.bar.background, 1.05)
                                    onClicked: root.doRestore(modelData)
                                }
                            }

                            Text {
                                text: "󰆴"
                                color: Qt.darker(Color.bar.text, 1.4)
                                font.pixelSize: 13
                                Layout.alignment: Qt.AlignVCenter

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    hoverEnabled: true
                                    enabled: !root.isRestoring && !root.isSnapshotting
                                    onContainsMouseChanged: parent.parent.color = containsMouse ? "#663333" : "transparent"
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
                    onContainsMouseChanged: parent.parent.color = containsMouse ? root.selectedBg : root.hoverBg
                    onClicked: confirmSave()
                }
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: Qt.darker(Color.bar.background, 1.05)

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
                    onContainsMouseChanged: parent.parent.color = containsMouse ? Qt.darker(Color.bar.text, 1.1) : Qt.darker(Color.bar.background, 1.05)
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
        listProc.command = ["bash", "-lc",
            "ls " + Util.shellQuote(root.profileDir) + "/*.json 2>/dev/null || true"]
        listProc.running = true
    }

    Process {
        id: listProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var files = text.trim().split("\n").filter(f => f.length > 0)
                var loaded = []
                for (var i = 0; i < files.length; i++) {
                    var name = files[i].replace(/^.*\//, "").replace(/\.json$/, "")
                    loaded.push(name)
                }
                root.profiles = loaded
            }
        }
    }

    // --- Snapshot ---

    function doSnapshot() {
        root.isSnapshotting = true
        root.lastAction = "Capturing..."
        snapClientsProc.running = true
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
                    root.isSnapshotting = false
                    root.lastAction = "Failed to capture windows"
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
                            "fullscreen": c.fullscreen
                        })
                    }
                    root.pendingSnapshot = {
                        "timestamp": Date.now(),
                        "windows": windows,
                        "monitors": monitors
                    }
                    root.isSnapshotting = false
                    root.lastAction = "Captured " + windows.length + " windows"
                    saveNameField.text = generateDefaultName()
                    root.showingNameInput = true
                } catch(e) {
                    root.isSnapshotting = false
                    root.lastAction = "Failed to capture monitors"
                }
            }
        }
    }

    // --- Save ---

    function doSave(name) {
        if (!root.pendingSnapshot || name.length === 0) return
        var path = root.validProfilePath(name)
        if (path === null) {
            root.lastAction = "Invalid profile name"
            return
        }
        var json = JSON.stringify(root.pendingSnapshot, null, 2)
        saveProc.command = ["bash", "-lc",
            "cat > " + Util.shellQuote(path) + " << 'WSRESTORE'\n" + json + "\nWSRESTORE"]
        saveProc.running = true
    }

    Process {
        id: saveProc
        command: []
        onExited: {
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
        var path = root.validProfilePath(name)
        if (path === null) {
            root.isRestoring = false
            root.lastAction = "Invalid profile name"
            return
        }
        root.isRestoring = true
        root.lastAction = "Restoring..."
        restoreProc.command = ["bash", "-lc", "cat " + Util.shellQuote(path)]
        restoreProc.running = true
    }

    Process {
        id: restoreProc
        command: []
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var profile = JSON.parse(text)
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
                try {
                    var existing = JSON.parse(text)
                } catch(e) {
                    existing = []
                }
                var profile = checkExistingProc._profile

                var lines = ["#!/bin/bash"]
                lines.push("LOGFILE=/tmp/wsrestorer-debug.log")
                lines.push("echo \"=== restore start $(date) ===\" > $LOGFILE")
                // Debug log written by the script itself (Quickshell's
                // execDetached logging is unavailable). Inspect
                // /tmp/wsrestorer-debug.log after a restore.
                lines.push("LOGFILE=/tmp/wsrestorer-debug.log; : > \"$LOGFILE\"")
                lines.push("echo \"[start] profile_windows=" + profile.windows.length + " existing=" + (existing ? existing.length : 0) + "\" >> \"$LOGFILE\"")

                // Track which profile windows have been matched
                var matched = []
                for (var p = 0; p < profile.windows.length; p++) matched[p] = false

                var toMove = []
                var toFloat = []
                var matchedAddrs = []

                if (existing && existing.length > 0) {
                    for (var i = 0; i < existing.length; i++) {
                        var e = existing[i]
                        var bestIdx = -1

                        // Match by class, then title for duplicates.
                        // Only claim the first unmatched class hit as a fallback,
                        // and only overwrite it on an exact title match - otherwise
                        // repeated scans keep clobbering bestIdx with the LAST
                        // same-class window instead of a stable pick.
                        for (var p = 0; p < profile.windows.length; p++) {
                            if (matched[p]) continue
                            if (e.class === profile.windows[p].class) {
                                if (bestIdx === -1) bestIdx = p
                                if (e.title === profile.windows[p].title) {
                                    bestIdx = p
                                    break
                                }
                            }
                        }

                        if (bestIdx >= 0) {
                            matched[bestIdx] = true
                            matchedAddrs.push(e.address)
                            var target = profile.windows[bestIdx]
                            var tws = root.safeWorkspace(target.workspace)
                            // Move to correct workspace if needed
                            if (tws !== null && String(e.workspace.name) !== String(target.workspace)) {
                                toMove.push({addr: e.address, ws: tws, cls: e.class, splitRatio: target.splitRatio, fullscreen: target.fullscreen})
                            }
                            // Restore floating state and position
                            if (target.floating) {
                                toFloat.push({addr: e.address, pos: target.position, size: target.size})
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
                    lines.push("hyprctl dispatch \"hl.dsp.workspace.move({workspace='" + wsName + "', monitor='" + wsToMonitor[wsName] + "'})\" 2>>\"$LOGFILE\" || true")
                }

                // Phase 1: Removed. We no longer SIGKILL unmatched windows and
                // no longer delete browser session caches - both were
                // destructive and could be driven by a crafted profile. Restore
                // now only moves matched windows and spawns missing ones.

                // Phase 2: Move matched windows to correct workspaces
                for (var m = 0; m < toMove.length; m++) {
                    var mv = toMove[m]
                    lines.push("echo \"[move-existing] ws=" + mv.ws + " addr=" + mv.addr + "\" >> \"$LOGFILE\"")
                    lines.push("hyprctl dispatch \"hl.dsp.window.move({workspace='" + mv.ws + "', window='address:" + mv.addr + "', follow=false})\" 2>>\"$LOGFILE\" || true")
                    // Restore fullscreen for windows captured fullscreen
                    if (mv.fullscreen) {
                        lines.push("hyprctl dispatch \"hl.dsp.window.fullscreen({mode='fullscreen', window='address:" + mv.addr + "'})\" 2>>\"$LOGFILE\" || true")
                    }
                }

                // Phase 2b: Apply floating state and positioning
                for (var f = 0; f < toFloat.length; f++) {
                    var fl = toFloat[f]
                    var fx = root.numOr(fl.pos[0])
                    var fy = root.numOr(fl.pos[1])
                    var fw = root.numOr(fl.size[0])
                    var fh = root.numOr(fl.size[1])
                    lines.push("hyprctl dispatch \"hl.dsp.window.float({action='toggle', window='address:" + fl.addr + "'})\" 2>>\"$LOGFILE\" || true")
                    lines.push("hyprctl dispatch \"hl.dsp.window.move({x=" + fx + ", y=" + fy + ", relative=false, window='address:" + fl.addr + "'})\" 2>>\"$LOGFILE\" || true")
                    lines.push("hyprctl dispatch \"hl.dsp.window.resize({x=" + fw + ", y=" + fh + ", window='address:" + fl.addr + "'})\" 2>>\"$LOGFILE\" || true")
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

                        // Launch file: exec the (already shell-quoted) command.
                        if (cmd.length === 0) {
                            lines.push("echo \"[launch] no safe command for ws=" + ws + "\" >> \"$LOGFILE\"")
                        }
                        var launchline
                        if (cmd.length > 0) launchline = "exec " + cmd
                        else launchline = "exit 1"
                        lines.push("SPATH=/tmp/wsrestorer-spawn-" + j + ".sh")
                        lines.push("printf '#!/bin/bash\\n%s\\n' " + root.shellArg(launchline) + " > $SPATH && chmod +x $SPATH")
                        // Focus the target workspace so the window lands on it
                        lines.push("hyprctl dispatch \"hl.dsp.focus({workspace='" + ws + "'})\" 2>>\"$LOGFILE\" || true")
                        lines.push("sleep 0.3")
                        lines.push("bash $SPATH &")
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
                    safety.push("LOGFILE=/tmp/wsrestorer-debug.log")
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
                    // restore notification. Launch base of the spawn scripts.
                    lines.push("SAFETY=/tmp/wsrestorer-safety.sh")
                    lines.push("printf '%s\\n' " + Util.shellQuote(safety.join("\n")) + " > $SAFETY && chmod +x $SAFETY")
                    lines.push("nohup bash $SAFETY >/dev/null 2>&1 &")
                    lines.push("disown")
                }

                lines.push("rm -f /tmp/wsrestorer-spawn-*.sh /tmp/wsrestorer-move.py 2>/dev/null")

                var totalCount = toMove.length + toFloat.length + spawnCount

                var scriptContent = lines.join("\n")
                var scriptPath = "/tmp/wsrestorer-restore.sh"
                masterRestoreProc._count = totalCount
                masterRestoreProc.command = ["bash", "-c",
                    "printf '%s\\n' " + Util.shellQuote(scriptContent) + " > " + scriptPath + " && chmod +x " + scriptPath + " && bash " + scriptPath]
                masterRestoreProc.running = true
            }
        }
    }

    Process {
        id: masterRestoreProc
        property int _count: 0
        command: ["bash", "-c", ""]
        onExited: function(exitCode) {
            root.isRestoring = false
            root.lastAction = "Restored " + _count + " windows"
            root.notify("Workspace restored", _count + " windows launched")
        }
    }

    // --- Delete ---

    function doDelete(name) {
        var path = root.validProfilePath(name)
        if (path === null) {
            root.lastAction = "Invalid profile name"
            return
        }
        delProc.command = ["bash", "-lc", "rm -f " + Util.shellQuote(path)]
        delProc.running = true
    }

    Process {
        id: delProc
        onExited: {
            root.lastAction = "Deleted"
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
}
