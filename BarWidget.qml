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
                } catch(e) {
                    console.log("WSRESTORE: failed to parse monitors JSON: " + e)
                }
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
                    snapCmdlinesProc.command = ["bash", "-lc", "for p in " + pids.join(" ") + "; do cat /proc/$p/cmdline 2>/dev/null | tr '\\0' ' '; echo; done"]
                    snapCmdlinesProc.running = true
                } catch(e) {
                    console.log("WSRESTORE: failed to parse clients JSON: " + e)
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
                    clients[i]._cmdline = (lines[i] || "").trim()
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
                    console.log("WSRESTORE: failed to parse monitors JSON: " + e)
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

    property var _restoreProfile: null
    property var _spawnWindows: []
    property int _spawnIndex: 0

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
                    console.log("WSRESTORE: failed to parse profile JSON: " + e)
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
                    console.log("WSRESTORE: failed to parse clients JSON: " + e)
                    existing = []
                }
                var profile = checkExistingProc._profile

                if (!existing || existing.length === 0) {
                    console.log("WSRESTORE: no existing windows, spawning directly")
                    root._restoreProfile = profile
                    root._spawnWindows = profile.windows
                    root._spawnIndex = 0
                    spawnNext()
                    return
                }

                console.log("WSRESTORE: found " + existing.length + " existing windows to kill")
                for (var i = 0; i < existing.length; i++) {
                    console.log("WSRESTORE-EXISTING[" + i + "]: pid=" + existing[i].pid + " class=" + existing[i].class)
                }

                // Close all existing windows by PID — kill entire process groups
                var killLines = ["#!/bin/bash", "echo 'WSRESTORE-KILL: starting'"]
                for (var i = 0; i < existing.length; i++) {
                    var win = existing[i]
                    killLines.push("echo 'WSRESTORE-KILL: killing pid=" + win.pid + " class=" + win.class + "'")
                    // Kill process group (negative PID) to catch child processes
                    killLines.push("kill -9 -" + win.pid + " 2>/dev/null || kill -9 " + win.pid + " 2>/dev/null")
                }
                // Also kill any orphaned browser background processes by name
                killLines.push("pkill -9 -f 'vivaldi-bin' 2>/dev/null || true")
                killLines.push("pkill -9 -f 'chrome' 2>/dev/null || true")
                killLines.push("pkill -9 -f 'firefox' 2>/dev/null || true")
                // Clear browser session files to prevent old tabs from resurrecting
                killLines.push("rm -f ~/.config/vivaldi/Default/'Last Session' 2>/dev/null || true")
                killLines.push("rm -f ~/.config/vivaldi/Default/'Last Tabs' 2>/dev/null || true")
                killLines.push("sleep 1")
                killLines.push("echo 'WSRESTORE-KILL: checking survivors'")
                killLines.push("pgrep -a vivaldi-bin || echo 'WSRESTORE-KILL: no vivaldi survivors'")
                killLines.push("pgrep -a -f kitty || echo 'WSRESTORE-KILL: no kitty survivors'")
                killLines.push("pgrep -a qbittorrent || echo 'WSRESTORE-KILL: no qbittorrent survivors'")
                killLines.push("pgrep -a nautilus || echo 'WSRESTORE-KILL: no nautilus survivors'")
                killLines.push("echo 'WSRESTORE-KILL: done'")
                var scriptContent = killLines.join("\n")
                var scriptPath = "/tmp/wsrestorer-kill.sh"
                // Write script and execute in one command
                killProc._profile = profile
                killProc.command = ["bash", "-c",
                    "printf '%s\\n' " + Util.shellQuote(scriptContent) + " > " + scriptPath + " && chmod +x " + scriptPath + " && bash " + scriptPath]
                killProc.running = true
                return
            }
        }
    }

    Process {
        id: killProc
        property var _profile: null
        command: ["bash", "-c", ""]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: { console.log("WSRESTORE-KILL-OUTPUT:\n" + text) }
        }
        onExited: function(exitCode) {
            console.log("WSRESTORE: kill script exited with code " + exitCode)
            console.log("WSRESTORE: spawning " + killProc._profile.windows.length + " windows")
            for (var i = 0; i < killProc._profile.windows.length; i++) {
                var w = killProc._profile.windows[i]
                console.log("WSRESTORE-SPAWN[" + i + "]: class=" + w.class + " ws=" + w.workspace + " cmd=" + w.command)
            }
            root._restoreProfile = killProc._profile
            root._spawnWindows = killProc._profile.windows
            root._spawnIndex = 0
            killThenSpawnTimer.restart()
        }
    }

    Timer {
        id: killThenSpawnTimer
        interval: 2000
        onTriggered: {
            // Clean up stale temp scripts before spawning
            Quickshell.execDetached(["bash", "-lc", "rm -f /tmp/wsrestorer-spawn-*.sh /tmp/wsrestorer-kill.sh"])
            spawnNext()
        }
    }

    property int spawnDelay: 400

    Timer {
        id: spawnTimer
        interval: root.spawnDelay
        onTriggered: {
            spawnNext()
        }
    }

    function spawnNext() {
        if (_spawnIndex >= _spawnWindows.length) {
            console.log("WSRESTORE: all " + _spawnWindows.length + " windows spawned")
            applyLayoutTimer._count = _spawnWindows.length
            applyLayoutTimer.restart()
            return
        }

        var win = _spawnWindows[_spawnIndex]
        var cmd = win.command || win.class.toLowerCase()
        console.log("WSRESTORE: spawn[" + _spawnIndex + "] class=" + win.class + " ws=" + win.workspace + " cmd=" + cmd)

        // Set a window rule matching the original class → target workspace
        var ruleCmd = "hyprctl eval \"hl.window_rule({match = {class = '" + win.class + "'}, workspace = '" + win.workspace + "'})\""
        Quickshell.execDetached(["bash", "-lc", ruleCmd])

        // Write command to temp script to preserve quoting (e.g. inner bash -c)
        var scriptPath = "/tmp/wsrestorer-spawn-" + _spawnIndex + ".sh"
        Quickshell.execDetached(["bash", "-lc",
            "printf '#!/bin/bash\\n%s\\n' " + Util.shellQuote(cmd) + " > " + scriptPath + " && chmod +x " + scriptPath + " && bash " + scriptPath])

        _spawnIndex++
        spawnTimer.restart()
    }

    Timer {
        id: applyLayoutTimer
        interval: 1500
        property int _count: 0
        onTriggered: {
            // Cleanup temp spawn scripts
            Quickshell.execDetached(["bash", "-lc", "rm -f /tmp/wsrestorer-spawn-*.sh"])
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
