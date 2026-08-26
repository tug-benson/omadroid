# 📱 Omadroid

An [Omarchy](https://omarchy.org) plugin to view and control an Android phone
right from the bar, using **scrcpy** and **ADB**.

The widget shows a 📱 icon in the bar. Clicking it opens a panel:

- **Top of the panel** — configuration (connection mode USB / WiFi, WiFi IP,
  scrcpy window size, Connect / Wake / Disconnect buttons, status).
- **Bottom of the panel** — a live preview of the phone screen + an **Open screen**
  button that launches the interactive scrcpy window.

The status line shows the connection type, device model and battery level, with
a colored dot (green = USB, orange = WiFi, red = disconnected). The last used
WiFi IP and mode are remembered between sessions.

> Unlocking the screen is done physically (fingerprint / PIN) on the device.
> The **Wake** button turns the screen on so the preview shows up.

---

## 🔒 Security

- **USB is the default transport** (most secure — no network traffic).
- **WiFi is opt-in** and must be enabled manually in the panel. It uses the
  standard ADB TCP/IP port `5555`.

---

## 🛠️ Prerequisites

| Tool | Install (Arch / Omarchy) |
|------|--------------------------|
| `adb` | `sudo pacman -S android-tools` |
| `scrcpy` | `sudo pacman -S scrcpy` |

**On the phone:**
- Enable **USB debugging** (Settings → Developer options)
- Accept the ADB authorization prompt on first USB connection

**WiFi mode (optional — less secure than USB):**
- The phone and the computer must be on the **same Wi-Fi network**.
- For the **first** WiFi connection, keep the phone plugged in over USB: the
  plugin enables ADB-over-TCP (`adb tcpip 5555`) through the USB link, then
  switches to WiFi. After that you can unplug and reconnect over WiFi using
  only the phone IP.
- Use a **stable IP** (static lease or DHCP reservation) so the IP does not
  change between sessions. If it changes, just update the IP field in the panel.
- If your phone runs Android 11+, you can also pair via **Wireless debugging**
  (Settings → Developer options) instead of the USB bootstrap.

**Quality (optional):** Omadroid already launches scrcpy with good defaults
(`--max-size 1080 --video-bit-rate 16M --max-fps 60`). To override or add
scrcpy flags, export `SCRCPY_OPTS` in your shell. The plugin appends it to the
command it builds.

```sh
# bash  → add to ~/.bashrc
# zsh   → add to ~/.zshrc
export SCRCPY_OPTS="--max-fps 60 --video-bit-rate 8M"
```

> Note: the variable above only reaches the plugin if it is exported in the
> session that starts Omarchy (your shell rc, or the environment of your
> display manager / WM). Since Omadroid already ships sensible quality defaults,
> this is optional.

---

## 🚀 Install

```sh
omarchy plugin add https://github.com/tug-benson/omadroid.git --enable
```

The widget appears in the `right` section of the bar (move it with
`omarchy bar move com.github.tug-benson.omadroid --section <left|center|right>`).

---

## 💡 Usage

1. Plug the phone in over USB and accept the ADB authorization.
2. Click the 📱 icon → the panel shows the live preview.
3. Click **Open screen** to launch the interactive scrcpy window
   (size is adjustable, ~6–8″ equivalent by default).
4. Unlock the phone physically, then use it like a window.

**WiFi mode (optional):** in the panel, pick **WiFi**, enter the phone IP, click
**Connect**. The first time, the phone must be plugged in over USB (the plugin
enables TCP/IP via USB, then switches to WiFi).

---

## ⚙️ Configuration

Settings (WiFi IP, max size, mode) are persisted to
`~/.config/omarchy/omadroid.conf`.

| Setting | Description | Default |
|---------|-------------|---------|
| Mode | USB (default) or WiFi | `usb` |
| WiFi IP | Phone address in WiFi mode | _(empty)_ |
| Size | `--max-size` of the scrcpy window | `420` |

---

## 🗑️ Uninstall

```sh
omarchy plugin remove com.github.tug-benson.omadroid
```

---

## 📄 License

MIT — see [LICENSE](LICENSE).
