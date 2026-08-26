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
- Enable **Developer options** (Settings → About phone → tap *Build number* 7 times).
- Enable **USB debugging** (Settings → Developer options). This is required for
  ADB/scrcpy to talk to the phone at all — nothing works without it.
- On Android 11+, also enable **Wireless debugging** if you plan to use WiFi mode
  without the USB bootstrap.
- Accept the ADB authorization prompt on first USB connection.

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

## ⌨️ Keyboard shortcut (open screen directly)

The plugin can open the scrcpy window straight from a keybinding. Add a bind
to your Hyprland config (`~/.config/hypr/bindings.lua` or `*.conf`):

```lua
-- bindings.lua (Omarchy uses Lua config)
bind("$mainMod", "p", "exec", "$HOME/.config/omarchy/plugins/com.github.tug-benson.omadroid/scripts/omadroid.sh open")
```

```ini
# hyprland.conf style
bind = $mainMod, P, exec, $HOME/.config/omarchy/plugins/com.github.tug-benson.omadroid/scripts/omadroid.sh open
```

`open` auto-detects the transport: it uses a plugged-in USB device, or falls
back to the saved WiFi IP. Set `SCRCPY_OPTS` (see Quality above) in the session
that starts Omarchy to tune it.

## ✨ Features

- **USB by default, WiFi optional** (remembers the last WiFi IP and mode).
- **Auto-connect over WiFi** when you open the panel and an IP is known.
- **Multiple devices**: if several phones are detected, a device picker lets
  you choose which one to mirror.
- **Resolution toggle** for the scrcpy window: **1080p** / **720p**.
- **Live preview** with **Rotate** (⟳) and **Expand** (▣) controls.
- **Direct touch control**: tap and swipe directly on the preview to drive the
  phone (maps to `adb input tap` / `swipe`, accounting for preview rotation).
- **Battery level** and a colored connection indicator in the status line.

## ⚙️ Configuration

Settings (WiFi IP, max size, mode) are persisted to
`~/.config/omarchy/omadroid.conf`.

| Setting | Description | Default |
|---------|-------------|---------|
| Mode | USB (default) or WiFi | `usb` |
| WiFi IP | Phone address in WiFi mode | _(empty)_ |
| Resolution | `--max-size` of the scrcpy window (`1080` or `720`) | `1080` |

---

## 🗑️ Uninstall

```sh
omarchy plugin remove com.github.tug-benson.omadroid
```

---

## 📄 License

MIT — see [LICENSE](LICENSE).
