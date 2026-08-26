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

                        Row {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 6

                            Text {
                                text: "󰋋"
                                color: Qt.darker(Color.bar.text, 1.4)
                                font.pixelSize: 13
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                text: modelData
                                color: Color.bar.text
                                font.family: Style.font.family
                                font.pixelSize: Style.font.body
                                anchors.verticalCenter: parent.verticalCenter
                                Layout.fillWidth: true
                                width: parent.width - 70
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
                                anchors.verticalCenter: parent.verticalCenter

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
                    var pids = clients.map(function(c) { return c.pid })
                    snapCmdlinesProc._clients = clients
                    snapCmdlinesProc.command = ["bash", "-lc", "for p in " + pids.join(" ") + "; do cat /proc/$p/cmdline 2>/dev/null | tr '\\0' ' '; echo '|CWD|' readlink /proc/$p/cwd 2>/dev/null; echo; done"]
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
                var lines = text.trim().split("\n")
                var clients = snapCmdlinesProc._clients
                for (var i = 0; i < clients.length; i++) {
                    var raw = (lines[i] || "").trim()
                    var cwdParts = raw.split("|CWD|")
                    clients[i]._cmdline = (cwdParts[0] || "").trim()
                    clients[i]._cwd = (cwdParts[1] || "").trim() || null
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
                    var seenPids = {}
                    for (var i = 0; i < clients.length; i++) {
                        var c = clients[i]
                        var monName = monMap[c.monitor] || String(c.monitor)

                        // Multiple windows from same PID share one command line.
                        // Only the first window keeps it; others fall back to class name.
                        var isFirstForPid = !seenPids[c.pid]
                        seenPids[c.pid] = true

                        windows.push({
                            "class": c.class,
                            "title": c.title,
                            "pid": c.pid,
                            "address": c.address,
                            "workspace": c.workspace.id,
                            "monitor": monName,
                            "monitorId": c.monitor,
                            "command": isFirstForPid ? (c._cmdline || null) : null,
                            "cwd": c._cwd || null,
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
        var path = root.profileDir + "/" + name + ".json"
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
        root.isRestoring = true
        root.lastAction = "Restoring..."
        var path = root.profileDir + "/" + name + ".json"
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

                // Terminal classes that support --directory / -D / --working-directory
                var terminalClasses = ["kitty", "foot", "Alacritty", "alacritty", "wezterm"]

                var lines = ["#!/bin/bash"]

                // Track which profile windows have been matched
                var matched = []
                for (var p = 0; p < profile.windows.length; p++) matched[p] = false

                var toKill = []
                var toMove = []
                var toFloat = []

                if (existing && existing.length > 0) {
                    for (var i = 0; i < existing.length; i++) {
                        var e = existing[i]
                        var bestIdx = -1

                        // Match by class, then title for duplicates
                        for (var p = 0; p < profile.windows.length; p++) {
                            if (matched[p]) continue
                            if (e.class === profile.windows[p].class) {
                                if (bestIdx === -1 || e.title === profile.windows[p].title) {
                                    bestIdx = p
                                    if (e.title === profile.windows[p].title) break
                                }
                            }
                        }

                        if (bestIdx >= 0) {
                            matched[bestIdx] = true
                            var target = profile.windows[bestIdx]
                            // Move to correct workspace if needed
                            if (e.workspace.id !== target.workspace) {
                                toMove.push({addr: e.address, ws: target.workspace, cls: e.class})
                            }
                            // Restore floating state and position
                            if (target.floating) {
                                toFloat.push({addr: e.address, pos: target.position, size: target.size})
                            }
                        } else {
                            toKill.push(e)
                        }
                    }
                }

                // Phase 1: Kill unmatched windows
                for (var k = 0; k < toKill.length; k++) {
                    lines.push("kill -9 " + toKill[k].pid + " 2>/dev/null || true")
                }

                // Clear browser session caches
                lines.push("rm -f ~/.config/vivaldi/Default/'Last Session' ~/.config/vivaldi/Default/'Last Tabs' 2>/dev/null || true")
                lines.push("rm -rf ~/.config/firefox/*/sessionstore-backups/* 2>/dev/null || true")
                lines.push("rm -f ~/.config/google-chrome/Default/'Current Session' ~/.config/google-chrome/Default/'Current Tabs' 2>/dev/null || true")
                lines.push("rm -f ~/.config/chromium/Default/'Current Session' ~/.config/chromium/Default/'Current Tabs' 2>/dev/null || true")

                // Phase 2: Move matched windows to correct workspaces
                for (var m = 0; m < toMove.length; m++) {
                    var mv = toMove[m]
                    lines.push("hyprctl dispatch \"hl.dsp.window.move({workspace='" + mv.ws + "', address='" + mv.addr + "', follow=false})\" 2>/dev/null || true")
                }

                // Phase 2b: Apply floating state and positioning
                for (var f = 0; f < toFloat.length; f++) {
                    var fl = toFloat[f]
                    lines.push("hyprctl dispatch \"hl.dsp.window.float({action='toggle', address='" + fl.addr + "'})\" 2>/dev/null || true")
                    lines.push("hyprctl dispatch \"hl.dsp.window.move({x=" + fl.pos[0] + ", y=" + fl.pos[1] + ", relative=false, address='" + fl.addr + "'})\" 2>/dev/null || true")
                    lines.push("hyprctl dispatch \"hl.dsp.window.resize({x=" + fl.size[0] + ", y=" + fl.size[1] + ", address='" + fl.addr + "'})\" 2>/dev/null || true")
                }

                // Phase 3: Spawn missing windows (only those not matched)
                var spawnCount = 0
                for (var j = 0; j < profile.windows.length; j++) {
                    if (!matched[j]) {
                        var w = profile.windows[j]
                        var cmd = w.command || w.class.toLowerCase()

                        // For terminal apps, inject saved CWD
                        if (w.cwd && terminalClasses.indexOf(w.class) >= 0) {
                            var cls = w.class.toLowerCase()
                            if (cls === "kitty") cmd = "kitty --directory " + w.cwd
                            else if (cls === "foot") cmd = "foot -D " + w.cwd
                            else if (cls === "alacritty") cmd = "alacritty --working-directory " + w.cwd
                        }

                        // Focus target workspace, wait, then launch (blocking, no &)
                        lines.push("hyprctl dispatch \"hl.dsp.focus({workspace='" + w.workspace + "'})\" 2>/dev/null || true")
                        lines.push("sleep 0.2")
                        var escaped = cmd.replace(/'/g, "'\\''")
                        lines.push("SPATH=/tmp/wsrestorer-spawn-" + j + ".sh")
                        lines.push("printf '#!/bin/bash\\n%s\\n' '" + escaped + "' > $SPATH && chmod +x $SPATH && bash $SPATH")
                        spawnCount++
                    }
                }

                lines.push("sleep 1")
                lines.push("rm -f /tmp/wsrestorer-spawn-*.sh 2>/dev/null")

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
        var path = root.profileDir + "/" + name + ".json"
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
