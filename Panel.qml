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
            anchors.margins: Style.space(12)
            spacing: Style.space(12)

            Rectangle {
              width: Style.space(46)
              height: Style.space(92)
              radius: Style.space(10)
              color: "#0d1117"
              border.color: Util.alpha(root.fg(), 0.35)
              border.width: 2
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(5)
                radius: Style.space(6)
                color: root.connected === "none" ? Util.alpha(root.fg(), 0.06) : Util.alpha(root.glowColor(), 0.4)
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
            }

            Column {
              width: parent.width - Style.space(46) - parent.spacing
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
                spacing: Style.space(8)
                Rectangle {
                  width: Style.space(110)
                  height: Style.space(8)
                  radius: height / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: Util.alpha(root.fg(), 0.15)
                  Rectangle {
                    width: parent.width * root.battFrac
                    height: parent.height
                    radius: parent.radius
                    color: root.glowColor()
                  }
                }
                Text {
                  text: root.battery + "%"
                  color: Util.alpha(root.fg(), 0.85)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
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
        Item {
          width: parent.width
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

        // WiFi IP (only relevant in WiFi mode)
        Row {
          visible: root.mode === "wifi"
          spacing: Style.space(8)
          width: parent.width
          Text {
            text: "IP"
            color: Util.alpha(root.fg(), 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
          TextField {
            id: ipField
            width: parent.width - Style.space(40)
            foreground: root.fg()
            placeholderText: "192.168.1.x"
            text: root.wifiIp
            onTextChanged: root.wifiIp = text
            onAccepted: root.saveConfig()
            onEditingFinished: root.saveConfig()
          }
        }

        // Device picker (chips wrap; selecting one aligns the mode)
        Flow {
          visible: root.devices.count > 0
          width: parent.width
          spacing: Style.space(8)
          Repeater {
            model: root.devices
            Button {
              text: (model.transport === "wifi" ? "WiFi · " : "USB · ") + (model.name || model.serial)
              tooltipText: model.serial
              bordered: true
              foreground: root.fg()
              background: "transparent"
              selected: root.selectedSerial === model.serial
              onClicked: root.selectDevice(model.serial, true)
            }
          }
        }

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

        Row {
          spacing: Style.space(8)
          width: parent.width
          Button {
            text: root.busyConnect ? "Connecting…" : "Connect"
            id: connectBtn
            tooltipText: "Connect the phone (USB, or WiFi if selected)"
            bordered: true
            foreground: root.fg()
            background: "transparent"
            SequentialAnimation on opacity {
              running: root.busyConnect
              loops: Animation.Infinite
              NumberAnimation { from: 1.0; to: 0.55; duration: 700; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
              onRunningChanged: if (!running) connectBtn.opacity = 1.0
            }
            onClicked: root.doConnect()
          }
          Button {
            text: "Disconnect"
            tooltipText: "Disconnect ADB and close our scrcpy window"
            bordered: true
            foreground: root.fg()
            background: "transparent"
            onClicked: root.doDisconnect()
          }
        }

        // ── SCREEN (primary action) ─────────────────────────────────
        PanelSeparator { foreground: root.fg() }
        PanelSectionHeader {
          text: "SCREEN"
          foreground: root.fg()
          fontFamily: Style.font.family
        }

        Button {
          width: parent.width
          text: "Open screen"
          tooltipText: "Launch the interactive scrcpy window"
          foreground: root.fg()
          background: "transparent"
          bordered: !root.canInteract
          active: root.canInteract
          opacity: root.canInteract ? 1.0 : 0.55
          onClicked: root.doOpen()
        }

        Row {
          spacing: Style.space(8)
          width: parent.width
          Button {
            text: "Wake"
            tooltipText: "Turn the phone screen on"
            bordered: true
            foreground: root.fg()
            background: "transparent"
            onClicked: root.doWake()
          }
          ButtonGroup {
            options: [
              { value: "1080", label: "1080p", tooltip: "Scrcpy window quality (~6–8″ equivalent)" },
              { value: "720", label: "720p", tooltip: "Smaller, lighter scrcpy window" }
            ]
            value: String(root.maxSize)
            foreground: root.fg()
            background: "transparent"
            focusable: false
            onChanged: function(v) { root.maxSize = parseInt(v) || 1080; root.saveConfig() }
          }
        }

        // ── PHONE keys (collapsible, open by default) ───────────────
        PanelSeparator { foreground: root.fg() }
        Row {
          id: phoneHead
          width: parent.width
          spacing: Style.space(6)
          property bool open: true
          Text {
            text: phoneHead.open ? "\uF078" : "\uF054"
            color: Util.alpha(root.fg(), 0.7)
            font.family: root.iconFont
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          PanelSectionHeader {
            text: "PHONE"
            foreground: root.fg()
            fontFamily: Style.font.family
            anchors.verticalCenter: parent.verticalCenter
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: phoneHead.open = !phoneHead.open
          }
        }

        Item {
          width: parent.width
          height: phoneHead.open ? phoneBody.height : 0
          clip: true
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          Column {
            id: phoneBody
            width: parent.width
            spacing: Style.space(6)
          Row {
            width: parent.width
            spacing: Style.space(6)
            Button { iconText: "\uDB80\uDC4D"; tooltipText: "Back"; fontFamily: root.iconFont; foreground: root.fg(); background: "transparent"; bordered: true; width: (parent.width - parent.spacing * 5) / 6; onClicked: root.sendKey("KEYCODE_BACK") }
            Button { iconText: "\uDB80\uDEDC"; tooltipText: "Home"; fontFamily: root.iconFont; foreground: root.fg(); background: "transparent"; bordered: true; width: (parent.width - parent.spacing * 5) / 6; onClicked: root.sendKey("KEYCODE_HOME") }
            Button { iconText: "\uDB80\uDC3B"; tooltipText: "Recents"; fontFamily: root.iconFont; foreground: root.fg(); background: "transparent"; bordered: true; width: (parent.width - parent.spacing * 5) / 6; onClicked: root.sendKey("KEYCODE_APP_SWITCH") }
            Button { iconText: "\uDB81\uDC25"; tooltipText: "Power"; fontFamily: root.iconFont; foreground: root.fg(); background: "transparent"; bordered: true; width: (parent.width - parent.spacing * 5) / 6; onClicked: root.sendKey("KEYCODE_POWER") }
            Button { iconText: "\uDB81\uDF5E"; tooltipText: "Volume down"; fontFamily: root.iconFont; foreground: root.fg(); background: "transparent"; bordered: true; width: (parent.width - parent.spacing * 5) / 6; onClicked: root.sendKey("KEYCODE_VOLUME_DOWN") }
            Button { iconText: "\uDB81\uDF5D"; tooltipText: "Volume up"; fontFamily: root.iconFont; foreground: root.fg(); background: "transparent"; bordered: true; width: (parent.width - parent.spacing * 5) / 6; onClicked: root.sendKey("KEYCODE_VOLUME_UP") }
          }
        }
        }

        // -- DEVICE (collapsible, closed by default) ───────────────────
        PanelSeparator { foreground: root.fg() }
        Row {
          id: deviceHead
          width: parent.width
          spacing: Style.space(6)
          property bool open: false
          Text {
            text: deviceHead.open ? "\uF078" : "\uF054"
            color: Util.alpha(root.fg(), 0.7)
            font.family: root.iconFont
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          PanelSectionHeader {
            text: "DEVICE"
            foreground: root.fg()
            fontFamily: Style.font.family
            anchors.verticalCenter: parent.verticalCenter
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: deviceHead.open = !deviceHead.open
          }
        }

        Item {
          width: parent.width
          height: deviceHead.open ? deviceBody.height : 0
          clip: true
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          Column {
            id: deviceBody
            width: parent.width
            spacing: Style.space(6)

          // Device system stats (RAM / CPU / storage) — hidden when offline
          Row {
            visible: root.connected !== "none"
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

          Grid {
            id: tileGrid
            width: parent.width
            columns: 2
            spacing: Style.space(8)
            Repeater {
              model: [
                { key: "wifi", label: "WiFi" },
                { key: "bt", label: "Bluetooth" },
                { key: "data", label: "Mobile data" },
                { key: "airplane", label: "Airplane" }
              ]
              Rectangle {
                width: (tileGrid.width - tileGrid.spacing) / 2
                height: Style.space(66)
                radius: Style.cornerRadius
                property bool tileOn: root.toggleState(modelData.key)
                color: tileOn ? Util.alpha(Color.accent, 0.22) : Util.alpha(root.fg(), 0.06)
                border.color: tileOn ? Util.alpha(Color.accent, 0.65) : Util.alpha(root.fg(), 0.18)
                border.width: 1
                Behavior on color { ColorAnimation { duration: 150 } }
                Column {
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  spacing: Style.space(2)
                  Row {
                    spacing: Style.space(8)
                    Rectangle {
                      width: Style.space(8)
                      height: Style.space(8)
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: tileOn ? Color.accent : Util.alpha(root.fg(), 0.3)
                    }
                    Text {
                      text: modelData.label
                      color: root.fg()
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                  Text {
                    text: tileOn ? "On" : "Off"
                    color: Util.alpha(root.fg(), 0.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.doToggle(modelData.key)
                }
              }
            }
          }
        }
        }
        }

        // -- PREVIEW (read-only — use Open screen to interact) ────
        PanelSeparator { foreground: root.fg() }
        PanelSectionHeader {
          text: "PREVIEW"
          foreground: root.fg()
          fontFamily: Style.font.family
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


          Column {
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
        }
      }
    }
  }
}
