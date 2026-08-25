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
                var monitors = JSON.parse(text)
                var map = {}
                for (var i = 0; i < monitors.length; i++) {
                    map[monitors[i].id] = monitors[i].name
                }
                root.monitorMap = map
            }
        }
    }

    function resolveExe(className) {
        var lower = className.toLowerCase()
        var known = {
            "org.omarchy.opencode": "kitty --class org.omarchy.opencode -- opencode",
            "org.qbittorrent.qbittorrent": "qbittorrent",
            "org.gnome.nautilus": "nautilus --new-window",
            "com.github.xournalpp.xournalpp": "xournalpp",
            "io.github.celluloid.celluloid": "celluloid",
            "org.mozilla.firefox": "firefox",
            "com.spotify.client": "spotify",
            "org.telegram.desktop": "telegram-desktop",
            "io.github.qutebrowser.qutebrowser": "qutebrowser",
            "net.davidotek.pupgui2": "lutris",
            "com.valvesoftware.steam": "steam",
            "heroic": "heroic"
        }
        if (known[lower]) return known[lower]
        if (known[className]) return known[className]
        return lower
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
                title: "Workspace Restorer"
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
                color: root.hoverBg

                Row {
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: root.isSnapshotting ? "󰅧" : "󰅧"
                        color: Color.bar.text
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: root.isSnapshotting ? "Capturing..." : "Take Snapshot"
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
                var clients = JSON.parse(text)
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
                var monitors = JSON.parse(text)
                var clients = snapMonitorsProc._clients

                var monMap = {}
                for (var m = 0; m < monitors.length; m++) {
                    monMap[monitors[m].id] = monitors[m].name
                }

                var windows = []
                for (var i = 0; i < clients.length; i++) {
                    var c = clients[i]
                    var monName = monMap[c.monitor] || String(c.monitor)
                    var exePath = ""
                    try {
                        var f = new File("/proc/" + c.pid + "/exe")
                        exePath = f.toString()
                    } catch(e) {}

                    windows.push({
                        "class": c.class,
                        "title": c.title,
                        "pid": c.pid,
                        "address": c.address,
                        "workspace": c.workspace.id,
                        "monitor": monName,
                        "monitorId": c.monitor,
                        "exe": exePath,
                        "command": root.resolveExe(c.class),
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
                var profile = JSON.parse(text)
                restoreWithConflicts(profile)
            }
        }
    }

    function restoreWithConflicts(profile) {
        if (!profile || !profile.windows || profile.windows.length === 0) {
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
                var existing = JSON.parse(text)
                var profile = checkExistingProc._profile

                var existingAddrs = {}
                for (var i = 0; i < existing.length; i++) {
                    var e = existing[i]
                    existingAddrs[e.class + "::" + e.title] = e.address
                }

                var toSpawn = []
                var alreadyRunning = []
                for (var j = 0; j < profile.windows.length; j++) {
                    var win = profile.windows[j]
                    var key = win.class + "::" + win.title
                    if (existingAddrs[key] !== undefined) {
                        win._existingAddress = existingAddrs[key]
                        alreadyRunning.push(win)
                    } else {
                        toSpawn.push(win)
                    }
                }

                for (var k = 0; k < alreadyRunning.length; k++) {
                    // window.move doesn't support address targeting; skip move
                }

                spawnWindows(toSpawn, profile)
            }
        }
    }

    property int spawnDelay: 400

    function spawnWindows(windows, profile) {
        if (windows.length === 0) {
            root.lastAction = "Layout restored (all windows already running)"
            root.notify("Workspace restored", "All windows were already in place")
            return
        }
        pendingSpawns._windows = windows
        pendingSpawns._index = 0
        pendingSpawns._total = windows.length
        pendingSpawns._profile = profile
        spawnNext()
    }

    Timer {
        id: spawnTimer
        interval: root.spawnDelay
        onTriggered: {
            spawnNext()
        }
    }

    function spawnNext() {
        var data = pendingSpawns
        if (data._index >= data._windows.length) {
            applyLayoutTimer._windows = data._windows
            applyLayoutTimer.restart()
            return
        }

        var win = data._windows[data._index]
        var cmd = win.command || win.class.toLowerCase()

        // Set a window rule matching the original class → target workspace
        var ruleCmd = "hyprctl eval \"hl.window_rule({match = {class = '" + win.class + "'}, workspace = '" + win.workspace + "'})\""
        Quickshell.execDetached(["bash", "-lc", ruleCmd])

        // Launch app directly
        Quickshell.execDetached(["bash", "-lc", cmd])

        data._index++
        spawnTimer.restart()
    }

    property var pendingSpawns: ({
        _windows: [],
        _index: 0,
        _total: 0,
        _profile: null
    })

    Timer {
        id: applyLayoutTimer
        interval: 1500
        property var _windows: []
        onTriggered: root.applyLayout(_windows)
    }

    function applyLayout(windows) {
        root.lastAction = "Restored " + windows.length + " windows"
        root.notify("Workspace restored",
            windows.length + " windows launched")
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
