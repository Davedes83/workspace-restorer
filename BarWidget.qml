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

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    Component.onCompleted: refreshProfiles()

    function notify(summary, body) {
        Quickshell.execDetached(["notify-send", "-a", "Workspace Restorer", "-i", "preferences-desktop-workspaces", summary, body || ""])
    }

    function generateDefaultName() {
        var d = new Date()
        var pad = function(n) { return n < 10 ? "0" + n : "" + n }
        return "snapshot-" + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
               "-" + pad(d.getHours()) + pad(d.getMinutes())
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
        contentHeight: showingNameInput ? 200 : 380

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
        }

        Column {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 6
            visible: !root.showingNameInput

            Row {
                width: parent.width
                spacing: 8

                Text {
                    text: "󰆞"
                    color: Color.bar.text
                    font.pixelSize: 16
                }

                Text {
                    text: "Workspace Restorer"
                    color: Color.bar.text
                    font: Style.font.heading
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Color.alpha(Color.bar.text, 0.2)
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: Color.alpha(Color.bar.text, 0.1)

                Text {
                    anchors.centerIn: parent
                    text: root.isSnapshotting ? "  Capturing..." : "  Take Snapshot"
                    color: Color.bar.text
                    font: Style.font.body
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.doSnapshot()
                }
            }

            Text {
                text: "Profiles"
                color: Color.alpha(Color.bar.text, 0.6)
                font: Style.font.italic
            }

            Column {
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.profiles

                    delegate: Rectangle {
                        width: parent.width
                        height: 36
                        radius: Style.cornerRadius
                        color: Color.alpha(Color.bar.text, 0.05)

                        Row {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 4

                            Text {
                                text: "󰋋  " + modelData
                                color: Color.bar.text
                                font: Style.font.body
                                anchors.verticalCenter: parent.verticalCenter
                                Layout.fillWidth: true
                                width: parent.width - 40

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.doRestore(modelData)
                                }
                            }

                            Text {
                                text: "󰆴"
                                color: Color.alpha(Color.bar.text, 0.5)
                                font.pixelSize: 14
                                anchors.verticalCenter: parent.verticalCenter

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
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
                color: Color.alpha(Color.bar.text, 0.5)
                font: Style.font.italic
                visible: root.lastAction !== ""
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // --- Name Input View ---

        Column {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8
            visible: root.showingNameInput

            Row {
                width: parent.width
                spacing: 8

                Text {
                    text: "󰆞"
                    color: Color.bar.text
                    font.pixelSize: 16
                }

                Text {
                    text: "Save Snapshot"
                    color: Color.bar.text
                    font: Style.font.heading
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Color.alpha(Color.bar.text, 0.2)
            }

            TextField {
                id: saveNameField
                width: parent.width
                placeholderText: "Profile name"
                color: Color.bar.text
                font: Style.font.body
                background: Rectangle {
                    color: Color.alpha(Color.bar.text, 0.1)
                    radius: Style.cornerRadius
                }
                Keys.onReturnPressed: confirmSave()
                Keys.onEnterPressed: confirmSave()
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: Color.alpha(Color.bar.text, 0.1)

                Text {
                    anchors.centerIn: parent
                    text: "  Save"
                    color: Color.bar.text
                    font: Style.font.body
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: confirmSave()
                }
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: Color.alpha(Color.bar.text, 0.05)

                Text {
                    anchors.centerIn: parent
                    text: "Cancel"
                    color: Color.alpha(Color.bar.text, 0.6)
                    font: Style.font.body
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
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
                var windows = []
                for (var i = 0; i < clients.length; i++) {
                    var c = clients[i]
                    windows.push({
                        "class": c.class,
                        "title": c.title,
                        "pid": c.pid,
                        "address": c.address,
                        "workspace": c.workspace.id,
                        "monitor": c.monitor,
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
                        alreadyRunning.push(win)
                    } else {
                        toSpawn.push(win)
                    }
                }

                for (var k = 0; k < alreadyRunning.length; k++) {
                    var rw = alreadyRunning[k]
                    var moveCmd = "hyprctl dispatch movetoworkspace " + rw.workspace +
                        ",address:" + rw.address
                    Quickshell.execDetached(["bash", "-lc", moveCmd])
                }

                spawnWindows(toSpawn, profile)
            }
        }
    }

    property int spawnDelay: 300

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
        onTriggered: spawnNext()
    }

    function spawnNext() {
        var data = pendingSpawns
        if (data._index >= data._windows.length) {
            applyLayoutTimer._profile = data._profile
            applyLayoutTimer._windows = data._windows
            applyLayoutTimer.restart()
            return
        }

        var win = data._windows[data._index]
        var cmd = "hyprctl dispatch exec " +
            "[workspace " + win.workspace + ":silent] " +
            "[monitor " + Util.shellQuote(win.monitor) + ":silent] " +
            win.class.toLowerCase()
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
        interval: 1000
        property var _profile: null
        property var _windows: []
        onTriggered: root.applyLayout(_windows, _profile)
    }

    function applyLayout(windows, profile) {
        var count = 0
        for (var i = 0; i < windows.length; i++) {
            var win = windows[i]
            if (win.floating) {
                var posCmd = "hyprctl dispatch movewindowpixel exact " +
                    win.position[0] + " " + win.position[1] + ",class:" + win.class
                Quickshell.execDetached(["bash", "-lc", posCmd])
            }
            if (win.splitRatio && win.splitRatio !== 1.0) {
                var ratioCmd = "hyprctl dispatch splitratio " +
                    win.splitRatio + ",class:" + win.class
                Quickshell.execDetached(["bash", "-lc", ratioCmd])
                count++
            }
        }
        root.lastAction = "Restored " + windows.length + " windows, " + count + " ratios"
        root.notify("Workspace restored",
            windows.length + " windows, " + count + " tile ratios applied")
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
