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
  property string glyph: "📱"
  property string mode: "usb"            // "usb" | "wifi"
  property string wifiIp: ""
  property int maxSize: 1080
  property string connected: "none"      // "none" | "usb" | "wifi"
  property string statusText: "Not connected"
  property string battery: ""
  property string previewSource: ""
  property int previewToken: 0
  readonly property string previewPath: runtimeDir + "/omadroid-preview.png"
  property string selectedSerial: ""     // empty = auto (first device)
  property ListModel devices: ListModel {}
  property int previewRotation: 0
  property bool previewExpanded: false
  property int deviceW: 1080
  property int deviceH: 2340
  property string sysRam: ""
  property string sysCpu: ""
  property string sysStorage: ""
  property string wifiSsid: ""
  property string wifiRssi: ""
  property bool toggleWifi: false
  property bool toggleBt: false
  property bool toggleData: false
  property bool toggleAirplane: false
  readonly property string iconFont: (root.bar && root.bar.fontFamily) ? root.bar.fontFamily : "CaskaydiaMono Nerd Font"

  function localPath(url) {
    var s = String(url)
    if (s.indexOf("file://") === 0) s = s.substring(7)
    return s
  }
  property string scriptPath: localPath(Qt.resolvedUrl("scripts/omadroid.sh"))
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/omadroid.conf"
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || ((Quickshell.env("HOME") || "/tmp") + "/.cache")) + "/omadroid"
  readonly property string devicesPath: runtimeDir + "/omadroid-devices.json"

  function open() {
    root.controller.show()
    root.loadConfig()
    root.refreshDevices()
    if (root.mode === "wifi" && root.wifiIp && root.connected === "none") root.doConnect()
    root.refreshStatus()
    root.refreshSysinfo()
    root.refreshToggles()
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
      root.deviceW = parseInt(s.w) || 1080
      root.deviceH = parseInt(s.h) || 2340
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

  function refreshSysinfo() {
    if (root.connected === "none" && !root.selectedSerial) return
    if (sysinfoProc.running) return
    var args = [root.scriptPath, "sysinfo"]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    sysinfoProc.command = args
    sysinfoProc.running = true
  }

  function applySysinfo(text) {
    if (!text) return
    try {
      var s = JSON.parse(text.trim())
      root.sysRam = (s.ram_used ? s.ram_used : "0") + " / " + (s.ram_total ? s.ram_total : "0") + " GB"
      root.sysCpu = (s.cpu_load != null ? s.cpu_load : "0") + " %"
      root.sysStorage = (s.storage_free ? s.storage_free : "0") + " / " + (s.storage_total ? s.storage_total : "0") + " GB"
      root.wifiSsid = s.ssid || ""
      root.wifiRssi = s.rssi || ""
    } catch (e) {}
  }

  function refreshToggles() {
    if (root.connected === "none" && !root.selectedSerial) return
    if (togglesProc.running) return
    var args = [root.scriptPath, "toggles"]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    togglesProc.command = args
    togglesProc.running = true
  }

  function applyToggles(text) {
    if (!text) return
    try {
      var s = JSON.parse(text.trim())
      root.toggleWifi = !!s.wifi
      root.toggleBt = !!s.bt
      root.toggleData = !!s.data
      root.toggleAirplane = !!s.airplane
    } catch (e) {}
  }

  function doToggle(name) {
    if (root.connected === "none" && !root.selectedSerial) return
    var args = [root.scriptPath, "toggle", name]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    togglesProc.command = args
    togglesProc.running = true
  }

  function brightness(dir) {
    if (root.connected === "none" && !root.selectedSerial) return
    var args = [root.scriptPath, "brightness", dir]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    Quickshell.execDetached(args)
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
      if (root.devices.count > 0) {
        var found = false
        if (root.selectedSerial) {
          for (var j = 0; j < root.devices.count; j++) {
            if (root.devices.get(j).serial === root.selectedSerial) { found = true; break }
          }
        }
        if (!found) root.selectDevice(root.devices.get(0).serial)
      } else {
        root.selectedSerial = ""
      }
    } catch (e) {
      root.devices.clear()
    }
  }

  function selectDevice(serial) {
    root.selectedSerial = serial
    root.refreshStatus()
    root.refreshPreview()
    root.refreshToggles()
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
      else if (k === "max_size") { root.maxSize = parseInt(v) || 1080 }
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
    var wantWifi = (m === "wifi")
    // keep the current selection only if its transport matches the new mode
    var keep = root.selectedSerial && ((root.selectedSerial.indexOf(":") >= 0) === wantWifi)
    if (!keep) {
      var chosen = ""
      for (var i = 0; i < root.devices.count; i++) {
        var d = root.devices.get(i)
        if ((d.serial.indexOf(":") >= 0) === wantWifi) { chosen = d.serial; break }
      }
      root.selectedSerial = chosen
    }
    syncModeButtons()
    root.saveConfig()
    root.refreshStatus()
    root.refreshPreview()
    root.refreshToggles()
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

  function savePreview() {
    if (root.connected === "none" && !root.selectedSerial) return
    Quickshell.execDetached([root.scriptPath, "save"])
  }

  function sendSwipe(x1, y1, x2, y2, dur) {
    if (root.connected === "none" && !root.selectedSerial) return
    var args = [root.scriptPath, "swipe", "" + x1, "" + y1, "" + x2, "" + y2, "" + dur]
    if (root.selectedSerial) args.push("--serial", root.selectedSerial)
    Quickshell.execDetached(args)
  }

  // Map a click position (in preview-box coordinates) to device screen
  // coordinates, undoing the preview rotation and the aspect-fit letterboxing.
  function previewToDevice(mx, my) {
    var boxW = previewBox.width, boxH = previewBox.height
    var px = mx - boxW / 2, py = my - boxH / 2
    var ux, uy, r = root.previewRotation
    if (r === 0)      { ux = px;        uy = py }
    else if (r === 90)  { ux = -py;       uy = px }
    else if (r === 180) { ux = -px;       uy = -py }
    else                { ux = py;        uy = -px }
    var x2 = ux + boxW / 2, y2 = uy + boxH / 2

    var imgAspect = (root.deviceW && root.deviceH) ? (root.deviceW / root.deviceH) : (1080 / 2340)
    var boxAspect = boxW / boxH
    var pixW, pixH, offX, offY
    if (boxAspect > imgAspect) {
      pixH = boxH; pixW = boxH * imgAspect; offX = (boxW - pixW) / 2; offY = 0
    } else {
      pixW = boxW; pixH = boxW / imgAspect; offX = 0; offY = (boxH - pixH) / 2
    }
    var nx = (x2 - offX) / pixW, ny = (y2 - offY) / pixH
    nx = Math.max(0, Math.min(1, nx)); ny = Math.max(0, Math.min(1, ny))
    return [Math.round(nx * root.deviceW), Math.round(ny * root.deviceH)]
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
        // transient capture failure -> keep the previous frame instead of
        // blanking (a momentary adb hiccup shouldn't clear the preview)
      }
    }
  }

  Process {
    id: devicesProc
    command: [root.scriptPath, "devices"]
    onExited: devicesFile.reload()
  }

  Process {
    id: sysinfoProc
    onExited: sysinfoFile.reload()
  }

  Process {
    id: togglesProc
    onExited: togglesFile.reload()
  }

  FileView {
    id: stateFile
    path: runtimeDir + "/omadroid-state.json"
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

  FileView {
    id: sysinfoFile
    path: runtimeDir + "/omadroid-sysinfo.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applySysinfo(text())
    onLoadFailed: root.applySysinfo("")
  }

  FileView {
    id: togglesFile
    path: runtimeDir + "/omadroid-toggles.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyToggles(text())
    onLoadFailed: root.applyToggles("")
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
    onTriggered: { root.refreshStatus(); root.refreshDevices(); root.refreshToggles() }
  }

  Timer {
    id: wakeTimer
    interval: 600
    repeat: false
    onTriggered: root.refreshPreview()
  }

  Timer {
    id: sysinfoTimer
    interval: 5000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.refreshSysinfo()
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

        Row {
          spacing: Style.space(8)
          width: parent.width
          Text {
            id: titleGlyph
            text: "\uDB80\uDD1C"
            color: root.fg()
            font.family: root.iconFont
            font.pixelSize: Style.font.title
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: titleText
            text: "Omadroid"
            color: root.fg()
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Item {
            width: parent.width - titleGlyph.width - titleText.width - Style.space(16)
            height: wifiInfo.height
            Column {
              id: wifiInfo
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              visible: root.wifiSsid !== ""
              Text {
                text: "\uDB81\uDDA9 " + (root.wifiSsid || "—")
                color: root.fg()
                font.family: root.iconFont
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
              }
              Text {
                visible: root.wifiRssi !== ""
                text: root.wifiRssi + " dBm"
                color: Util.alpha(root.fg(), 0.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignRight
              }
            }
          }
        }

        // Mode selector + live status (same line)
        Row {
          spacing: Style.space(8)
          width: parent.width
          Row {
            id: modeRow
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
          Rectangle {
            width: Style.space(12)
            height: Style.space(12)
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.connected === "none" ? "#e5484d"
                 : (root.connected === "usb" ? "#30a46c" : "#f5a623")
          }
          Text {
            visible: root.battery !== ""
            text: "\uDB80\uDC79 " + root.battery + "%"
            color: root.fg()
            font.family: root.iconFont
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: root.statusText
            color: root.fg()
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            elide: Text.ElideRight
            width: Math.max(Style.space(40), parent.width - modeRow.width - Style.space(70))
            anchors.verticalCenter: parent.verticalCenter
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

        // Device picker + Resolution (always shows the connected device(s), separator before resolution)
        Row {
          spacing: Style.space(8)
          width: parent.width
          Repeater {
            model: root.devices
            PanelButton {
              label: (model.transport === "wifi" ? "WiFi" : "USB") + " : " + (model.name || model.serial)
              fg: root.fg()
              active: root.selectedSerial === model.serial
              onClicked: root.selectDevice(model.serial)
            }
          }
          Rectangle {
            visible: root.devices.count > 0
            width: 1
            height: Style.space(24)
            color: Util.alpha(root.fg(), 0.3)
          }
          PanelButton {
            label: "1080p"
            width: Style.space(70)
            fg: root.fg()
            active: root.maxSize === 1080
            onClicked: { root.maxSize = 1080; root.saveConfig() }
          }
          PanelButton {
            label: "720p"
            width: Style.space(70)
            fg: root.fg()
            active: root.maxSize === 720
            onClicked: { root.maxSize = 720; root.saveConfig() }
          }
        }

        // Action buttons
        Row {
          spacing: Style.space(8)
          PanelButton { label: "Connect"; fg: root.fg(); onClicked: root.doConnect() }
          PanelButton { label: "Wake"; fg: root.fg(); onClicked: root.doWake() }
          PanelButton { label: "Disconnect"; fg: root.fg(); onClicked: root.doDisconnect() }
          Rectangle {
            width: 1
            height: Style.space(24)
            color: Util.alpha(root.fg(), 0.3)
          }
          PanelButton { label: "Open screen"; fg: root.fg(); onClicked: root.doOpen() }
        }

        // Quick connectivity toggles (grouped 2x2 so they stay compact)
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.connected !== "none" || root.selectedSerial !== ""

          PanelSectionHeader {
            text: "QUICK TOGGLES"
            foreground: root.fg()
            fontFamily: Style.font.family
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.space(6)
              Toggle {
                width: parent.width
                label: "WiFi"
                checked: root.toggleWifi
                foreground: root.fg()
                fontFamily: Style.font.family
                onClicked: root.doToggle("wifi")
              }
              Toggle {
                width: parent.width
                label: "Bluetooth"
                checked: root.toggleBt
                foreground: root.fg()
                fontFamily: Style.font.family
                onClicked: root.doToggle("bt")
              }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.space(6)
              Toggle {
                width: parent.width
                label: "Mobile data"
                checked: root.toggleData
                foreground: root.fg()
                fontFamily: Style.font.family
                onClicked: root.doToggle("data")
              }
              Toggle {
                width: parent.width
                label: "Airplane mode"
                checked: root.toggleAirplane
                foreground: root.fg()
                fontFamily: Style.font.family
                onClicked: root.doToggle("airplane")
              }
            }
          }
        }

        // Device system stats (RAM / CPU / storage)
        Row {
          width: parent.width
          spacing: Style.space(8)
          property real cpuW: Style.space(80)

          Rectangle {
            width: (parent.width - parent.spacing * 2 - parent.cpuW) / 2
            height: Style.space(48)
            radius: Style.cornerRadius
            border.color: Util.alpha(root.fg(), 0.18)
            border.width: 1
            color: Util.alpha(root.fg(), 0.04)
            Row {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)
              Text { text: "\uEFC5"; color: root.fg(); font.family: root.iconFont; font.pixelSize: Style.space(24); anchors.verticalCenter: parent.verticalCenter }
              Text { text: root.sysRam || "—"; color: Util.alpha(root.fg(), 0.9); font.family: Style.font.family; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight }
            }
          }
          Rectangle {
            width: parent.cpuW
            height: Style.space(48)
            radius: Style.cornerRadius
            border.color: Util.alpha(root.fg(), 0.18)
            border.width: 1
            color: Util.alpha(root.fg(), 0.04)
            Row {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)
              Text { text: "\uF4BC"; color: root.fg(); font.family: root.iconFont; font.pixelSize: Style.space(24); anchors.verticalCenter: parent.verticalCenter }
              Text { text: root.sysCpu || "—"; color: Util.alpha(root.fg(), 0.9); font.family: Style.font.family; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight }
            }
          }
          Rectangle {
            width: (parent.width - parent.spacing * 2 - parent.cpuW) / 2
            height: Style.space(48)
            radius: Style.cornerRadius
            border.color: Util.alpha(root.fg(), 0.18)
            border.width: 1
            color: Util.alpha(root.fg(), 0.04)
            Row {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)
              Text { text: "\uE8B3"; color: root.fg(); font.family: root.iconFont; font.pixelSize: Style.space(24); anchors.verticalCenter: parent.verticalCenter }
              Text { text: root.sysStorage || "—"; color: Util.alpha(root.fg(), 0.9); font.family: Style.font.family; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight }
            }
          }
        }

        // Device controls (full panel width)
        Row {
          width: parent.width
          spacing: Style.space(6)
          PanelButton { label: "\uDB80\uDC4D"; iconFont: root.iconFont; width: (parent.width - parent.spacing * 5) / 6; fg: root.fg(); onClicked: root.sendKey("KEYCODE_BACK") }
          PanelButton { label: "\uDB80\uDEDC"; iconFont: root.iconFont; width: (parent.width - parent.spacing * 5) / 6; fg: root.fg(); onClicked: root.sendKey("KEYCODE_HOME") }
          PanelButton { label: "\uDB80\uDC3B"; iconFont: root.iconFont; width: (parent.width - parent.spacing * 5) / 6; fg: root.fg(); onClicked: root.sendKey("KEYCODE_APP_SWITCH") }
          PanelButton { label: "\uDB81\uDC25"; iconFont: root.iconFont; width: (parent.width - parent.spacing * 5) / 6; fg: root.fg(); onClicked: root.sendKey("KEYCODE_POWER") }
          PanelButton { label: "\uDB81\uDF5E"; iconFont: root.iconFont; width: (parent.width - parent.spacing * 5) / 6; fg: root.fg(); onClicked: root.sendKey("KEYCODE_VOLUME_DOWN") }
          PanelButton { label: "\uDB81\uDF5D"; iconFont: root.iconFont; width: (parent.width - parent.spacing * 5) / 6; fg: root.fg(); onClicked: root.sendKey("KEYCODE_VOLUME_UP") }
        }

        // Preview
        Rectangle {
          id: previewBox
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

          MouseArea {
            anchors.fill: parent
            property int startX: 0
            property int startY: 0
            property bool down: false
            onPressed: function(e) {
              if (root.connected === "none" && !root.selectedSerial) return
              startX = e.x; startY = e.y; down = true
            }
            onReleased: function(e) {
              if (!down) return
              down = false
              if (root.connected === "none" && !root.selectedSerial) return
                var s = root.previewToDevice(startX, startY)
                var cur = root.previewToDevice(e.x, e.y)
                if (Math.abs(e.x - startX) < 12 && Math.abs(e.y - startY) < 12)
                  root.sendSwipe(s[0], s[1], s[0], s[1], 1)
                else
                  root.sendSwipe(s[0], s[1], cur[0], cur[1], 80)
            }
          }

          Column {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(8)
            spacing: Style.space(6)
            PanelButton { label: "\uDB81\uDC67"; iconFont: root.iconFont; width: Style.space(40); height: Style.space(40); fg: root.fg(); onClicked: root.rotatePreview() }
            PanelButton { label: root.previewExpanded ? "\uDB80\uDE94" : "\uDB80\uDE93"; iconFont: root.iconFont; width: Style.space(40); height: Style.space(40); fg: root.fg(); onClicked: root.previewExpanded = !root.previewExpanded }
            PanelButton { label: "\uDB80\uDCDB"; iconFont: root.iconFont; width: Style.space(40); height: Style.space(40); fg: root.fg(); onClicked: root.brightness("down") }
            PanelButton { label: "\uDB80\uDCE0"; iconFont: root.iconFont; width: Style.space(40); height: Style.space(40); fg: root.fg(); onClicked: root.brightness("up") }
            PanelButton { label: "\uDB80\uDD93"; iconFont: root.iconFont; width: Style.space(40); height: Style.space(40); fg: root.fg(); onClicked: root.savePreview() }
          }
        }
      }
    }
  }
}
