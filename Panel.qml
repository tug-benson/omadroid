import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "com.github.tug-benson.omadroid"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // ── state ────────────────────────────────────────────────────────────────
  property string mode: "usb"            // "usb" | "wifi"
  property string wifiIp: ""
  property int maxSize: 420
  property string connected: "none"      // "none" | "usb" | "wifi"
  property string statusText: "Non connecté"
  property string previewSource: ""
  property int previewToken: 0
  readonly property string previewPath: "/tmp/omadroid-preview.png"

  function localPath(url) {
    var s = String(url)
    if (s.indexOf("file://") === 0) s = s.substring(7)
    return s
  }
  property string scriptPath: localPath(Qt.resolvedUrl("scripts/omadroid.sh"))

  function open() {
    root.controller.show()
    root.loadConfig()
    root.refreshStatus()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function fg() { return root.barForeground ? root.barForeground : "#ffffff" }

  // ── actions ────────────────────────────────────────────────────────────────
  function refreshStatus() {
    if (statusProc.running) return
    statusProc.running = true
  }

  function applyStatus(text) {
    try {
      var s = JSON.parse(text.trim())
      root.connected = s.connected || "none"
      if (root.connected === "usb")
        root.statusText = "Connected (USB)" + (s.model ? " — " + s.model : "")
      else if (root.connected === "wifi")
        root.statusText = "Connected (WiFi" + (s.ip ? " " + s.ip : "") + ")" + (s.model ? " — " + s.model : "")
      else
        root.statusText = s.error ? "Not connected — " + s.error : "Not connected"
      root.refreshPreview()
    } catch (e) {
      root.statusText = "Status error"
    }
  }

  function doConnect() {
    root.saveConfig()
    if (connectProc.running) return
    var args = [root.scriptPath, "connect"]
    if (root.mode === "wifi") {
      args.push("--wifi")
      if (root.wifiIp) args.push("--ip", root.wifiIp)
    }
    connectProc.command = args
    connectProc.running = true
  }

  function doOpen() {
    if (root.connected === "none") { root.statusText = "Connect the phone first"; return }
    var args = ["scrcpy", "--max-size", String(root.maxSize), "--window-title", "Omadroid"]
    if (root.mode === "wifi") {
      if (!root.wifiIp) { root.statusText = "WiFi IP required"; return }
      args.push("--tcpip=" + root.wifiIp + ":5555")
    }
    Quickshell.execDetached(args)
  }

  function doWake() {
    if (root.connected === "none") return
    Quickshell.execDetached([root.scriptPath, "wake"])
    wakeTimer.restart()
  }

  function doDisconnect() {
    Quickshell.execDetached([root.scriptPath, "disconnect"])
    root.connected = "none"
    root.statusText = "Non connecté"
    root.previewSource = ""
    root.refreshStatus()
  }

  function refreshPreview() {
    if (root.connected === "none") { root.previewSource = ""; return }
    if (previewProc.running) return
    previewProc.running = true
  }

  function loadConfig() {
    if (cfgProc.running) return
    cfgProc.running = true
  }

  function parseConfig(text) {
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var kv = lines[i].split("=")
      if (kv.length < 2) continue
      var k = kv[0].trim(), v = kv[1].trim()
      if (k === "wifi_ip") { root.wifiIp = v; if (ipInput) ipInput.text = v }
      else if (k === "max_size") { root.maxSize = parseInt(v) || 420; if (sizeInput) sizeInput.text = String(root.maxSize) }
      else if (k === "mode") { root.mode = (v === "wifi") ? "wifi" : "usb"; syncModeButtons() }
    }
  }

  function saveConfig() {
    Quickshell.execDetached([root.scriptPath, "config", "set", "wifi_ip", root.wifiIp])
    Quickshell.execDetached([root.scriptPath, "config", "set", "max_size", String(root.maxSize)])
    Quickshell.execDetached([root.scriptPath, "config", "set", "mode", root.mode])
  }

  function setMode(m) {
    root.mode = m
    syncModeButtons()
    root.saveConfig()
  }

  function syncModeButtons() {
    usbBtn.active = (root.mode === "usb")
    wifiBtn.active = (root.mode === "wifi")
  }

  // ── processes ───────────────────────────────────────────────────────────────
  Process {
    id: statusProc
    command: [root.scriptPath, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: function(t) { root.applyStatus(t) } }
  }

  Process {
    id: connectProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: function(t) { root.applyStatus(t) } }
  }

  Process {
    id: cfgProc
    command: [root.scriptPath, "config", "dump"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: function(t) { root.parseConfig(t) } }
  }

  Process {
    id: previewProc
    command: [root.scriptPath, "preview", root.previewPath]
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.previewToken += 1
        root.previewSource = Util.fileUrl(root.previewPath) + "?" + root.previewToken
      } else {
        root.previewSource = ""
      }
    }
  }

  // ── timers ──────────────────────────────────────────────────────────────────
  Timer {
    id: previewTimer
    interval: 1000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.refreshPreview()
  }

  Timer {
    id: statusTimer
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: wakeTimer
    interval: 600
    repeat: false
    onTriggered: root.refreshPreview()
  }

  // ── UI ───────────────────────────────────────────────────────────────────────
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: "Omadroid"
          color: root.fg()
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        // Mode selector (USB default, WiFi opt-in)
        Row {
          spacing: Style.space(8)
          PanelButton {
            id: usbBtn
            label: "USB"
            fg: root.fg()
            active: root.mode === "usb"
            onClicked: root.setMode("usb")
          }
          PanelButton {
            id: wifiBtn
            label: "WiFi"
            fg: root.fg()
            active: root.mode === "wifi"
            onClicked: root.setMode("wifi")
          }
        }

        // WiFi IP (only relevant in WiFi mode)
        Row {
          visible: root.mode === "wifi"
          spacing: Style.space(8)
          width: parent.width
          Text {
            text: "IP"
            color: root.fg()
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
          TextInput {
            id: ipInput
            width: parent.width - Style.space(40)
            color: root.fg()
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            text: root.wifiIp
            onTextChanged: root.wifiIp = text
            onAccepted: root.saveConfig()
            Rectangle {
              anchors.fill: parent
              color: "transparent"
              border.color: Util.alpha(root.fg(), 0.25)
              border.width: 1
              radius: Style.cornerRadius
              z: -1
            }
          }
        }

        // Max window size for the scrcpy window
        Row {
          spacing: Style.space(8)
          width: parent.width
          Text {
            text: "Size"
            color: root.fg()
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
          TextInput {
            id: sizeInput
            width: Style.space(70)
            color: root.fg()
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            text: String(root.maxSize)
            validator: IntValidator { bottom: 120; top: 1200 }
            onTextChanged: root.maxSize = parseInt(text) || 420
            onAccepted: root.saveConfig()
            Rectangle {
              anchors.fill: parent
              color: "transparent"
              border.color: Util.alpha(root.fg(), 0.25)
              border.width: 1
              radius: Style.cornerRadius
              z: -1
            }
          }
          Text {
            text: "(scrcpy window)"
            color: Util.alpha(root.fg(), 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Status
        Text {
          width: parent.width
          text: root.statusText
          color: root.fg()
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // Action buttons
        Row {
          spacing: Style.space(8)
          PanelButton { label: "Connect"; fg: root.fg(); onClicked: root.doConnect() }
          PanelButton { label: "Wake"; fg: root.fg(); onClicked: root.doWake() }
          PanelButton { label: "Disconnect"; fg: root.fg(); onClicked: root.doDisconnect() }
        }

        // Live preview (bottom of the panel)
        Rectangle {
          width: parent.width
          height: Style.space(240)
          color: Util.alpha(root.fg(), 0.06)
          radius: Style.cornerRadius
          border.color: Util.alpha(root.fg(), 0.18)
          border.width: 1
          clip: true

          Image {
            anchors.centerIn: parent
            source: root.previewSource
            fillMode: Image.PreserveAspectFit
            height: parent.height - Style.space(12)
            width: parent.width - Style.space(12)
            asynchronous: true
            smooth: true
            visible: root.previewSource !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: root.previewSource === ""
            text: "Preview unavailable\n(connect the phone)"
            color: Util.alpha(root.fg(), 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }
        }

        PanelButton {
          label: "Open screen"
          fg: root.fg()
          onClicked: root.doOpen()
        }
      }
    }
  }
}
