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
  property int maxSize: 1080
  property string connected: "none"      // "none" | "usb" | "wifi"
  property string statusText: "Not connected"
  property string battery: ""
  property string previewSource: ""
  property int previewToken: 0
  readonly property string previewPath: "/tmp/omadroid-preview.png"
  property string selectedSerial: ""     // empty = auto (first device)
  property ListModel devices: ListModel {}
  property int previewRotation: 0
  property bool previewExpanded: false

  function localPath(url) {
    var s = String(url)
    if (s.indexOf("file://") === 0) s = s.substring(7)
    return s
  }
  property string scriptPath: localPath(Qt.resolvedUrl("scripts/omadroid.sh"))
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/omadroid.conf"
  readonly property string devicesPath: "/tmp/omadroid-devices.json"

  function open() {
    root.controller.show()
    root.loadConfig()
    root.refreshDevices()
    if (root.mode === "wifi" && root.wifiIp && root.connected === "none") root.doConnect()
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
    var args = [root.scriptPath, "status"]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    statusProc.command = args
    statusProc.running = true
  }

  function applyStatus(text) {
    if (!text) return
    try {
      var s = JSON.parse(text.trim())
      root.connected = s.connected || "none"
      root.battery = s.battery || ""
      if (root.connected === "usb")
        root.statusText = "Connected (USB)" + (s.model ? " — " + s.model : "")
      else if (root.connected === "wifi")
        root.statusText = "Connected (WiFi" + (s.ip ? " " + s.ip : "") + ")" + (s.model ? " — " + s.model : "")
      else
        root.statusText = s.error ? "Not connected — " + s.error : "Not connected"
      if (root.battery)
        root.statusText += "  🔋 " + root.battery + "%"
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
    if (root.connected === "none" && !root.selectedSerial) { root.statusText = "Connect the phone first"; return }
    var args = [root.scriptPath, "open", "--max-size", String(root.maxSize)]
    if (root.selectedSerial) {
      args.push("--serial", root.selectedSerial)
    } else if (root.mode === "wifi") {
      if (!root.wifiIp) { root.statusText = "WiFi IP required"; return }
      args.push("--wifi", "--ip", root.wifiIp)
    }
    Quickshell.execDetached(args)
  }

  function doWake() {
    if (root.connected === "none" && !root.selectedSerial) return
    var args = [root.scriptPath, "wake"]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    Quickshell.execDetached(args)
    wakeTimer.restart()
  }

  function doDisconnect() {
    Quickshell.execDetached([root.scriptPath, "disconnect"])
    root.connected = "none"
    root.statusText = "Not connected"
    root.battery = ""
    root.previewSource = ""
    root.refreshStatus()
  }

  function refreshPreview() {
    if (root.connected === "none" && !root.selectedSerial) { root.previewSource = ""; return }
    if (previewProc.running) return
    var args = [root.scriptPath, "preview", root.previewPath]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    previewProc.command = args
    previewProc.running = true
  }

  function refreshDevices() {
    if (devicesProc.running) return
    devicesProc.running = true
  }

  function parseDevices(text) {
    if (!text) { root.devices.clear(); return }
    try {
      var arr = JSON.parse(text)
      root.devices.clear()
      for (var i = 0; i < arr.length; i++)
        root.devices.append({ serial: arr[i].serial, transport: arr[i].transport, name: arr[i].name || "" })
      if (!root.selectedSerial && root.devices.count > 0)
        root.selectDevice(root.devices.get(0).serial)
    } catch (e) {
      root.devices.clear()
    }
  }

  function selectDevice(serial) {
    root.selectedSerial = serial
    root.refreshStatus()
    root.refreshPreview()
  }

  function loadConfig() {
    if (cfgProc.running) return
    cfgProc.running = true
  }

  function parseConfig(text) {
    if (!text) return
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var kv = lines[i].split("=")
      if (kv.length < 2) continue
      var k = kv[0].trim(), v = kv[1].trim()
      if (k === "wifi_ip") { root.wifiIp = v; if (ipInput) ipInput.text = v }
      else if (k === "max_size") { root.maxSize = parseInt(v) || 1080; if (sizeInput) sizeInput.text = String(root.maxSize) }
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

  function rotatePreview() {
    root.previewRotation = (root.previewRotation + 90) % 360
  }

  function sendKey(key) {
    if (root.connected === "none" && !root.selectedSerial) return
    var args = [root.scriptPath, "input", key]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    Quickshell.execDetached(args)
  }

  // ── processes (triggers; output is read from state files via FileView) ─────
  Process {
    id: statusProc
    onExited: stateFile.reload()
  }

  Process {
    id: connectProc
    onExited: stateFile.reload()
  }

  Process {
    id: cfgProc
    command: [root.scriptPath, "config", "dump"]
    onExited: configFile.reload()
  }

  Process {
    id: previewProc
    onExited: function(exitCode) {
      if (exitCode === 0) {
        // image changed -> refresh (and accept the small live-update flicker)
        root.previewToken += 1
        root.previewSource = Util.fileUrl(root.previewPath) + "?" + root.previewToken
      } else if (exitCode === 3) {
        // unchanged -> keep the current image (no flicker)
      } else {
        root.previewSource = ""
      }
    }
  }

  Process {
    id: devicesProc
    command: [root.scriptPath, "devices"]
    onExited: devicesFile.reload()
  }

  FileView {
    id: stateFile
    path: "/tmp/omadroid-state.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onLoadFailed: root.applyStatus("")
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseConfig(text())
    onLoadFailed: root.parseConfig("")
  }

  FileView {
    id: devicesFile
    path: root.devicesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseDevices(text())
    onLoadFailed: root.parseDevices("[]")
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
    onTriggered: { root.refreshStatus(); root.refreshDevices() }
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
    contentWidth: panel.fittedContentWidth(Style.space(440))
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
            validator: IntValidator { bottom: 120; top: 1600 }
            onTextChanged: root.maxSize = parseInt(text) || 1080
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

        // Status (with colored indicator)
        Row {
          spacing: Style.space(8)
          width: parent.width
          Rectangle {
            width: Style.space(12)
            height: Style.space(12)
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.connected === "none" ? "#e5484d"
                 : (root.connected === "usb" ? "#30a46c" : "#f5a623")
          }
          Text {
            width: parent.width - Style.space(20)
            text: root.statusText
            color: root.fg()
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }

        // Device picker (only when several devices are detected)
        Column {
          visible: root.devices.count > 1
          width: parent.width
          spacing: Style.space(6)
          Text {
            text: "Device"
            color: Util.alpha(root.fg(), 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Row {
            spacing: Style.space(6)
            Repeater {
              model: root.devices
              PanelButton {
                label: (model.transport === "wifi" ? "📶 " : "🔌 ") + (model.name || model.serial)
                fg: root.fg()
                active: root.selectedSerial === model.serial
                onClicked: root.selectDevice(model.serial)
              }
            }
          }
        }

        // Action buttons
        Row {
          spacing: Style.space(8)
          PanelButton { label: "Connect"; fg: root.fg(); onClicked: root.doConnect() }
          PanelButton { label: "Wake"; fg: root.fg(); onClicked: root.doWake() }
          PanelButton { label: "Disconnect"; fg: root.fg(); onClicked: root.doDisconnect() }
        }

        // Quick device controls
        Row {
          spacing: Style.space(6)
          PanelButton { label: "⏪"; fg: root.fg(); onClicked: root.sendKey("KEYCODE_BACK") }
          PanelButton { label: "⌂"; fg: root.fg(); onClicked: root.sendKey("KEYCODE_HOME") }
          PanelButton { label: "▢"; fg: root.fg(); onClicked: root.sendKey("KEYCODE_APP_SWITCH") }
          PanelButton { label: "⏻"; fg: root.fg(); onClicked: root.sendKey("KEYCODE_POWER") }
          PanelButton { label: "🔉"; fg: root.fg(); onClicked: root.sendKey("KEYCODE_VOLUME_DOWN") }
          PanelButton { label: "🔊"; fg: root.fg(); onClicked: root.sendKey("KEYCODE_VOLUME_UP") }
        }

        // Live preview (bottom of the panel)
        Rectangle {
          width: parent.width
          height: root.previewExpanded ? Style.space(680) : Style.space(440)
          color: Util.alpha(root.fg(), 0.06)
          radius: Style.cornerRadius
          border.color: Util.alpha(root.fg(), 0.18)
          border.width: 1
          clip: true

          Image {
            anchors.centerIn: parent
            rotation: root.previewRotation
            height: (root.previewRotation % 180 === 0) ? parent.height - Style.space(12) : parent.width - Style.space(12)
            width: (root.previewRotation % 180 === 0) ? parent.width - Style.space(12) : parent.height - Style.space(12)
            source: root.previewSource
            fillMode: Image.PreserveAspectFit
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

          // Preview controls (top-right)
          Row {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(8)
            spacing: Style.space(6)
            PanelButton { label: "⟳"; fg: root.fg(); onClicked: root.rotatePreview() }
            PanelButton { label: root.previewExpanded ? "▢" : "▣"; fg: root.fg(); onClicked: root.previewExpanded = !root.previewExpanded }
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
