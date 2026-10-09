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
  property bool busyConnect: false
  readonly property bool canInteract: root.connected !== "none" || root.selectedSerial !== ""
  property string deviceModel: ""
  readonly property real battFrac: Math.max(0, Math.min(1, (parseInt(root.battery) || 0) / 100))
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
  property real sysRamU: 0
  property real sysRamT: 0
  property real sysCpuL: 0
  property real sysDiskF: 0
  property real sysDiskT: 0
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
  function glowColor() {
    if (root.connected === "usb") return "#30a46c"
    if (root.connected === "wifi") return "#f5a623"
    return "#e5484d"
  }
  function barColor(frac, lowBad) {
    if (lowBad ? (frac < 0.2) : (frac > 0.9)) return "#e5484d"
    return root.glowColor()
  }

  function selectedDeviceLabel() {
    if (root.selectedSerial) {
      for (var i = 0; i < root.devices.count; i++) {
        var d = root.devices.get(i)
        if (d.serial === root.selectedSerial)
          return (d.transport === "wifi" ? "WiFi · " : "USB · ") + (d.name || d.serial)
      }
      return root.selectedSerial
    }
    return ""
  }

  function toggleState(k) {
    if (k === "wifi") return root.toggleWifi
    if (k === "bt") return root.toggleBt
    if (k === "data") return root.toggleData
    return root.toggleAirplane
  }

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
    root.busyConnect = false
    try {
      var s = JSON.parse(text.trim())
      root.connected = s.connected || "none"
      root.battery = s.battery || ""
      root.deviceW = parseInt(s.w) || 1080
      root.deviceModel = s.model || ""
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
    root.busyConnect = true
    root.statusText = "Connecting…"
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
    root.deviceModel = ""
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
      root.sysRamU = parseFloat(s.ram_used) || 0
      root.sysRamT = parseFloat(s.ram_total) || 0
      root.sysCpuL = parseFloat(s.cpu_load) || 0
      root.sysDiskF = parseFloat(s.storage_free) || 0
      root.sysDiskT = parseFloat(s.storage_total) || 0
      root.sysRam = root.sysRamU.toFixed(1) + "/" + root.sysRamT.toFixed(1) + " GB"
      root.sysCpu = Math.round(root.sysCpuL) + "%"
      root.sysStorage = Math.round(root.sysDiskF) + "/" + Math.round(root.sysDiskT) + " GB"
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
        if (!found) root.selectDevice(root.devices.get(0).serial, false)
      } else {
        root.selectedSerial = ""
      }
    } catch (e) {
      root.devices.clear()
    }
  }

  // fromUser=true (explicit tap on a device chip) also aligns the
  // transport mode with the device, so the two selectors never disagree.
  function selectDevice(serial, fromUser) {
    root.selectedSerial = serial
    if (fromUser === true && serial) {
      var want = (serial.indexOf(":") >= 0) ? "wifi" : "usb"
      if (root.mode !== want) {
        root.mode = want
        root.saveConfig()
      }
    }
    root.refreshStatus()
    root.refreshPreview()
    root.refreshToggles()
  }

  function cycleDevice() {
    if (root.devices.count < 2) return
    var idx = -1
    for (var i = 0; i < root.devices.count; i++) {
      if (root.devices.get(i).serial === root.selectedSerial) { idx = i; break }
    }
    root.selectDevice(root.devices.get((idx + 1) % root.devices.count).serial, true)
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
      if (k === "wifi_ip") { root.wifiIp = v; if (ipField) ipField.text = v }
      else if (k === "max_size") { root.maxSize = parseInt(v) || 1080 }
      else if (k === "mode") { root.mode = (v === "wifi") ? "wifi" : "usb" }
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
    root.saveConfig()
    root.refreshStatus()
    root.refreshPreview()
    root.refreshToggles()
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

  // ── processes (output is read from each process' stdout via StdioCollector) ──
  Process {
    id: statusProc
    stdout: StdioCollector { onStreamFinished: root.applyStatus(this.text) }
  }

  Process {
    id: connectProc
    stdout: StdioCollector { onStreamFinished: root.applyStatus(this.text) }
    // Safety net: a failing helper may exit without usable stdout.
    onExited: root.busyConnect = false
  }

  Process {
    id: cfgProc
    command: [root.scriptPath, "config", "dump"]
    stdout: StdioCollector { onStreamFinished: root.parseConfig(this.text) }
  }

  Process {
    id: previewProc
    onExited: function(exitCode) {
      if (exitCode === 0) {
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
    stdout: StdioCollector { onStreamFinished: root.parseDevices(this.text) }
  }

  Process {
    id: sysinfoProc
    stdout: StdioCollector { onStreamFinished: root.applySysinfo(this.text) }
  }

  Process {
    id: togglesProc
    stdout: StdioCollector { onStreamFinished: root.applyToggles(this.text) }
  }

  // ── timers ──────────────────────────────────────────────────────────────────
  Timer {
    id: previewTimer
    interval: 1000
    repeat: true
    running: root.opened && previewHead.open
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
        spacing: Style.space(8)

        Row {
          spacing: Style.space(8)
          width: parent.width
          Text {
            id: titleGlyph
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "\uDB80\uDD1C"
            color: root.fg()
            font.family: root.iconFont
            font.pixelSize: Style.space(34)
            transformOrigin: Item.Center
            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 6000
              loops: Animation.Infinite
            }
          }
          Column {
            id: titleCol
            spacing: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            Text {
              id: titleText
              textFormat: Text.PlainText
              text: "Omadroid"
              color: root.fg()
              font.family: Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
              font.letterSpacing: 1
            }
            Rectangle {
              width: titleText.implicitWidth
              height: Style.space(3)
              radius: height / 2
              color: root.glowColor()
            }
          }
          Item {
            width: parent.width - titleGlyph.width - titleCol.width - parent.spacing * 2
            height: titleGlyph.height
            PanelActionButton {
              id: githubBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uF09B"
              tooltipText: "Open repository on GitHub"
              fontFamily: root.iconFont
              foreground: Util.alpha(root.fg(), 0.7)
              onClicked: Qt.openUrlExternally("https://github.com/tug-benson/omadroid")
            }
            Column {
              id: wifiInfo
              anchors.right: githubBtn.left
              anchors.rightMargin: Style.space(8)
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

        // -- Hero (device at a glance) --
        Rectangle {
          width: parent.width
          height: heroRow.implicitHeight + Style.space(24)
          radius: Style.cornerRadius * 1.5
          color: Util.alpha(root.fg(), 0.05)
          border.color: Util.alpha(root.fg(), 0.16)
          border.width: 1

          Rectangle {
            id: heroGlow
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            radius: parent.radius + Style.space(4)
            color: "transparent"
            border.color: root.glowColor()
            border.width: 2
            opacity: 0.25
            z: -1
            SequentialAnimation on opacity {
              running: root.connected !== "none"
              loops: Animation.Infinite
              NumberAnimation { from: 0.3; to: 0.65; duration: 1600; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.65; to: 0.3; duration: 1600; easing.type: Easing.InOutSine }
              onRunningChanged: if (!running) heroGlow.opacity = 0.25
            }
          }

          Row {
            id: heroRow
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(12)

            Rectangle {
              width: Style.space(44)
              height: Style.space(88)
              radius: Style.space(10)
              color: "#0d1117"
              border.color: Util.alpha(root.fg(), 0.35)
              border.width: 2
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(5)
                radius: Style.space(6)
                color: (root.connected === "none" && !mockHover.containsMouse) ? Util.alpha(root.fg(), 0.06) : Util.alpha(root.glowColor(), mockHover.containsMouse ? 0.6 : 0.4)
                Behavior on color { ColorAnimation { duration: 300 } }
              }
              Rectangle {
                width: Style.space(16)
                height: Style.space(4)
                radius: Style.space(2)
                anchors.top: parent.top
                anchors.topMargin: Style.space(8)
                anchors.horizontalCenter: parent.horizontalCenter
                color: Util.alpha(root.fg(), 0.35)
              }
              MouseArea {
                id: mockHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.doOpen()
              }
              PanelToolTip {
                visible: mockHover.containsMouse
                text: "Open screen"
              }
            }

            Column {
              width: parent.width - Style.space(44) - heroToggles.width - parent.spacing * 2
              spacing: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                text: root.deviceModel !== "" ? root.deviceModel : "No phone connected"
                color: root.fg()
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                textFormat: Text.PlainText
                elide: Text.ElideRight
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                Rectangle {
                  width: Style.space(10)
                  height: Style.space(10)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.glowColor()
                }
                Text {
                  width: parent.width - Style.space(18)
                  text: root.statusText
                  color: Util.alpha(root.fg(), 0.85)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

               Row {
                visible: root.battery !== ""
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: Style.space(34)
                  text: "BAT"
                  color: Util.alpha(root.fg(), 0.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                  width: parent.width - Style.space(34) - Style.space(76) - parent.spacing * 2
                  height: Style.space(6)
                  radius: height / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: Util.alpha(root.fg(), 0.15)
                  Rectangle {
                    width: parent.width * (root.battFrac)
                    height: parent.height
                    radius: parent.radius
                    color: root.barColor(root.battFrac, true)
                  }
                }
                Text {
                  width: Style.space(76)
                  text: root.battery + "%"
                  color: Util.alpha(root.fg(), 0.85)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Row {
                visible: root.connected !== "none"
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: Style.space(34)
                  text: "RAM"
                  color: Util.alpha(root.fg(), 0.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                  width: parent.width - Style.space(34) - Style.space(76) - parent.spacing * 2
                  height: Style.space(6)
                  radius: height / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: Util.alpha(root.fg(), 0.15)
                  Rectangle {
                    width: parent.width * (root.sysRamT > 0 ? root.sysRamU / root.sysRamT : 0)
                    height: parent.height
                    radius: parent.radius
                    color: root.barColor(root.sysRamT > 0 ? root.sysRamU / root.sysRamT : 0, false)
                  }
                }
                Text {
                  width: Style.space(76)
                  text: root.sysRam
                  color: Util.alpha(root.fg(), 0.85)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Row {
                visible: root.connected !== "none"
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: Style.space(34)
                  text: "CPU"
                  color: Util.alpha(root.fg(), 0.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                  width: parent.width - Style.space(34) - Style.space(76) - parent.spacing * 2
                  height: Style.space(6)
                  radius: height / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: Util.alpha(root.fg(), 0.15)
                  Rectangle {
                    width: parent.width * (root.sysCpuL / 100)
                    height: parent.height
                    radius: parent.radius
                    color: root.barColor(root.sysCpuL / 100, false)
                  }
                }
                Text {
                  width: Style.space(76)
                  text: root.sysCpu
                  color: Util.alpha(root.fg(), 0.85)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Row {
                visible: root.connected !== "none"
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: Style.space(34)
                  text: "DISK"
                  color: Util.alpha(root.fg(), 0.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                  width: parent.width - Style.space(34) - Style.space(76) - parent.spacing * 2
                  height: Style.space(6)
                  radius: height / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: Util.alpha(root.fg(), 0.15)
                  Rectangle {
                    width: parent.width * (root.sysDiskT > 0 ? 1 - root.sysDiskF / root.sysDiskT : 0)
                    height: parent.height
                    radius: parent.radius
                    color: root.barColor(root.sysDiskT > 0 ? 1 - root.sysDiskF / root.sysDiskT : 0, false)
                  }
                }
                Text {
                  width: Style.space(76)
                  text: root.sysStorage
                  color: Util.alpha(root.fg(), 0.85)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Row {
                width: parent.width
                spacing: Style.space(4)
                Repeater {
                  model: [
                    { action: "connect", key: "", icon: root.connected !== "none" ? "\uDB81\uDEA6" : "\uDB81\uDEA5", tip: root.busyConnect ? "Connecting…" : (root.connected !== "none" ? "Disconnect" : "Connect") },
                    { action: "wake", key: "", icon: "\uDB85\uDC40", tip: "Wake" },
                    { action: "key", key: "KEYCODE_BACK", icon: "\uDB80\uDC4D", tip: "Back" },
                    { action: "key", key: "KEYCODE_HOME", icon: "\uDB80\uDEDC", tip: "Home" },
                    { action: "key", key: "KEYCODE_APP_SWITCH", icon: "\uDB80\uDC3B", tip: "Recents" },
                    { action: "key", key: "KEYCODE_POWER", icon: "\uDB81\uDC25", tip: "Power" },
                    { action: "key", key: "KEYCODE_VOLUME_DOWN", icon: "\uDB81\uDF5E", tip: "Volume down" },
                    { action: "key", key: "KEYCODE_VOLUME_UP", icon: "\uDB81\uDF5D", tip: "Volume up" }
                  ]
                  RoundButton {
                    size: Style.space(26)
                    iconSize: Style.space(15)
                    iconText: modelData.icon
                    tooltipText: modelData.tip
                    fontFamily: root.iconFont
                    foreground: root.fg()
                    opacity: (modelData.action === "connect" && root.busyConnect) ? 0.55 : 1.0
                    onClicked: {
                      if (modelData.action === "connect") {
                        if (root.connected !== "none") root.doDisconnect()
                        else root.doConnect()
                      } else if (modelData.action === "wake") root.doWake()
                      else root.sendKey(modelData.key)
                    }
                  }
                }
              }
            }
            Column {
              id: heroToggles
              width: Style.space(86)
              spacing: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              Rectangle {
                width: heroToggles.width
                height: Style.space(30)
                radius: Style.cornerRadius
                color: root.toggleState("wifi") ? Util.alpha("#2f81f7", 0.14) : Util.alpha(root.fg(), 0.06)
                border.color: root.toggleState("wifi") ? Util.alpha("#2f81f7", 0.55) : Util.alpha(root.fg(), 0.18)
                border.width: 1
                opacity: root.canInteract ? 1.0 : 0.5
                Behavior on color { ColorAnimation { duration: 150 } }
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  spacing: Style.space(4)
                    Text {
                      text: "\uDB81\uDDA9"
                      color: root.toggleState("wifi") ? "#2f81f7" : Util.alpha(root.fg(), 0.35)
                      font.family: root.iconFont
                      font.pixelSize: Style.space(16)
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  Text {
                    text: "WiFi"
                    color: root.fg()
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.doToggle("wifi")
                }
              }
              Rectangle {
                width: heroToggles.width
                height: Style.space(30)
                radius: Style.cornerRadius
                color: root.toggleState("bt") ? Util.alpha("#39c5cf", 0.14) : Util.alpha(root.fg(), 0.06)
                border.color: root.toggleState("bt") ? Util.alpha("#39c5cf", 0.55) : Util.alpha(root.fg(), 0.18)
                border.width: 1
                opacity: root.canInteract ? 1.0 : 0.5
                Behavior on color { ColorAnimation { duration: 150 } }
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  spacing: Style.space(4)
                    Text {
                      text: "\uDB80\uDCAF"
                      color: root.toggleState("bt") ? "#39c5cf" : Util.alpha(root.fg(), 0.35)
                      font.family: root.iconFont
                      font.pixelSize: Style.space(16)
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  Text {
                    text: "BT"
                    color: root.fg()
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.doToggle("bt")
                }
              }
              Rectangle {
                width: heroToggles.width
                height: Style.space(30)
                radius: Style.cornerRadius
                color: root.toggleState("data") ? Util.alpha("#3fb950", 0.14) : Util.alpha(root.fg(), 0.06)
                border.color: root.toggleState("data") ? Util.alpha("#3fb950", 0.55) : Util.alpha(root.fg(), 0.18)
                border.width: 1
                opacity: root.canInteract ? 1.0 : 0.5
                Behavior on color { ColorAnimation { duration: 150 } }
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  spacing: Style.space(4)
                    Text {
                      text: "\uF012"
                      color: root.toggleState("data") ? "#3fb950" : Util.alpha(root.fg(), 0.35)
                      font.family: root.iconFont
                      font.pixelSize: Style.space(16)
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  Text {
                    text: "Data"
                    color: root.fg()
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.doToggle("data")
                }
              }
              Rectangle {
                width: heroToggles.width
                height: Style.space(30)
                radius: Style.cornerRadius
                color: root.toggleState("airplane") ? Util.alpha("#d29922", 0.14) : Util.alpha(root.fg(), 0.06)
                border.color: root.toggleState("airplane") ? Util.alpha("#d29922", 0.55) : Util.alpha(root.fg(), 0.18)
                border.width: 1
                opacity: root.canInteract ? 1.0 : 0.5
                Behavior on color { ColorAnimation { duration: 150 } }
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  spacing: Style.space(4)
                    Text {
                      text: "\uDB80\uDC1D"
                      color: root.toggleState("airplane") ? "#d29922" : Util.alpha(root.fg(), 0.35)
                      font.family: root.iconFont
                      font.pixelSize: Style.space(16)
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  Text {
                    text: "Airplane"
                    color: root.fg()
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.doToggle("airplane")
                }
              }
            }
          }
        }

        // ── CONNECTION ──────────────────────────────────────────────
        PanelSeparator { foreground: root.fg() }
        PanelSectionHeader {
          text: "CONNECTION"
          foreground: root.fg()
          fontFamily: Style.font.family
        }

        // Transport segmented pill with sliding cursor
        Row {
          width: parent.width
          spacing: Style.space(8)
          Item {
            id: modePill
            width: Style.space(150)
            height: usbPillText.implicitHeight + Style.space(14)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Util.alpha(root.fg(), 0.08)
              border.color: Util.alpha(root.fg(), 0.16)
              border.width: 1
            }
            Rectangle {
              width: parent.width / 2 - Style.space(8)
              height: parent.height - Style.space(8)
              x: root.mode === "wifi" ? parent.width / 2 + Style.space(4) : Style.space(4)
              y: Style.space(4)
              radius: height / 2
              color: Util.alpha(root.fg(), 0.22)
              Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            }
            Row {
              anchors.fill: parent
              Text {
                id: usbPillText
                width: parent.width / 2
                height: parent.height
                text: "USB"
                color: root.fg()
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: root.mode === "usb"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
              }
              Text {
                width: parent.width / 2
                height: parent.height
                text: "WiFi"
                color: root.fg()
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: root.mode === "wifi"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
              }
            }
            Row {
              anchors.fill: parent
              Item {
                width: parent.width / 2
                height: parent.height
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setMode("usb")
                }
              }
              Item {
                width: parent.width / 2
                height: parent.height
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setMode("wifi")
                }
              }
            }
          }
            Item {
              width: parent.width - modePill.width - parent.spacing
              height: modePill.height
              anchors.verticalCenter: parent.verticalCenter
              TextField {
                id: ipField
                anchors.fill: parent
                visible: root.mode === "wifi"
                foreground: root.fg()
                placeholderText: "192.168.1.x"
                text: root.wifiIp
                onTextChanged: root.wifiIp = text
                onAccepted: root.saveConfig()
                onEditingFinished: root.saveConfig()
              }
              Button {
                anchors.fill: parent
                visible: root.mode === "usb"
                text: root.selectedSerial !== "" ? root.selectedDeviceLabel() : "No USB device"
                tooltipText: "Active USB device — click to switch"
                bordered: true
                foreground: root.fg()
                background: "transparent"
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.xs
                opacity: root.selectedSerial !== "" ? 1.0 : 0.55
                onClicked: root.cycleDevice()
              }
            }
        }


        // Device picker (chips wrap; selecting one aligns the mode)

        Text {
          visible: root.devices.count === 0 && root.connected === "none"
          width: parent.width
          text: "No device detected — plug the phone in over USB, or switch to WiFi and enter its IP."
          color: Util.alpha(root.fg(), 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }


        // ── SCREEN (primary action) ─────────────────────────────────





        // -- PREVIEW (read-only — use Open screen to interact) ────
        PanelSeparator { foreground: root.fg() }
        Item {
          id: previewHead
          width: parent.width
          height: previewTitle.implicitHeight
          property bool open: false
          Row {
            anchors.fill: parent
            spacing: Style.space(6)
            Text {
              text: previewHead.open ? "\uF078" : "\uF054"
              color: Util.alpha(root.fg(), 0.7)
              font.family: root.iconFont
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            PanelSectionHeader {
              id: previewTitle
              text: "PREVIEW"
              foreground: root.fg()
              fontFamily: Style.font.family
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: previewHead.open = !previewHead.open
          }
        }

        // Preview
        Item {
          width: parent.width
          height: previewHead.open ? previewBody.height : 0
          clip: true
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          Column {
            id: previewBody
            width: parent.width
            spacing: Style.space(6)
        Rectangle {
          id: previewBox
          width: parent.width
          height: root.previewExpanded ? Style.space(680) : Style.space(360)
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
            id: previewHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }

          Column {
            visible: previewHover.containsMouse && root.previewSource !== ""
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(8)
            spacing: Style.space(6)
            PanelActionButton { iconText: "\uDB81\uDC67"; tooltipText: "Rotate preview"; fontFamily: root.iconFont; foreground: root.fg(); size: Style.space(32); onClicked: root.rotatePreview() }
            PanelActionButton { iconText: root.previewExpanded ? "\uDB80\uDE94" : "\uDB80\uDE93"; tooltipText: "Expand preview"; fontFamily: root.iconFont; foreground: root.fg(); size: Style.space(32); onClicked: root.previewExpanded = !root.previewExpanded }
            PanelActionButton { iconText: "\uDB80\uDCDB"; tooltipText: "Brightness down"; fontFamily: root.iconFont; foreground: root.fg(); size: Style.space(32); onClicked: root.brightness("down") }
            PanelActionButton { iconText: "\uDB80\uDCE0"; tooltipText: "Brightness up"; fontFamily: root.iconFont; foreground: root.fg(); size: Style.space(32); onClicked: root.brightness("up") }
            PanelActionButton { iconText: "\uDB80\uDD93"; tooltipText: "Save snapshot"; fontFamily: root.iconFont; foreground: root.fg(); size: Style.space(32); onClicked: root.savePreview() }
          }
        }          }
        }
      }
    }
  }
}
