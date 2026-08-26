#!/usr/bin/env bash
# omadroid.sh — helper for the Omadroid Omarchy plugin
#
# Subcommands:
#   status [--serial S]              -> JSON {connected, ip, model, battery}
#   connect [--wifi] [--ip IP]       -> JSON status (USB first, optional WiFi)
#   wake [--serial S]                -> wake the device screen (keyevent WAKEUP)
#   disconnect                       -> drop WiFi ADB + close scrcpy
#   preview <outfile> [--serial S]   -> write a PNG screenshot to <outfile>
#   open [--serial S|--wifi --ip IP] -> launch the interactive scrcpy window
#   devices                          -> JSON array of {serial, transport, model}
#   save [dest]                      -> copy the current preview PNG to <dest>
#   config dump                      -> key=value lines (wifi_ip, max_size, mode)
#   config set <k> <v>               -> persist a setting
#
# Security: USB is the default transport. WiFi is opt-in and only used when
# the user explicitly selects the WiFi mode (and provides the phone IP).

set -u
ADB_PORT="${ADB_PORT:-5555}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
CONFIG_FILE="$CONFIG_DIR/omadroid.conf"
STATE_FILE="${OMADROID_STATE:-/tmp/omadroid-state.json}"
DEVICES_FILE="${OMADROID_DEVICES:-/tmp/omadroid-devices.json}"
PREVIEW_FILE="${OMADROID_PREVIEW:-/tmp/omadroid-preview.png}"

# ── config helpers ──────────────────────────────────────────────────────────
cfg_get() {
  local key="$1" def="$2" val=""
  [ -f "$CONFIG_FILE" ] && val=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
  echo "${val:-$def}"
}

cfg_set() {
  local key="$1" val="$2"
  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ] && grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
  else
    echo "${key}=${val}" >> "$CONFIG_FILE"
  fi
}

# ── device detection ─────────────────────────────────────────────────────────
usb_device() {
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -v ':' | awk '{print $1}' | head -1
}
wifi_device() {
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep ':' | awk '{print $1}' | head -1
}
any_device() {
  local u w
  u=$(usb_device); [ -n "$u" ] && { echo "$u"; return; }
  w=$(wifi_device); [ -n "$w" ] && { echo "$w"; return; }
  echo ""
}

emit_json() {
  echo "$1"
  printf '%s' "$1" > "$STATE_FILE"
}

emit_status_json() {
  local connected="$1" ip="$2" dev="$3" model="" battery="" w="" h=""
  [ -z "$dev" ] && dev="$ip"
  [ "$connected" = "wifi" ] && dev="$ip:$ADB_PORT"
  model=$(adb -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  battery=$(adb -s "$dev" shell dumpsys battery 2>/dev/null | grep -i "level:" | grep -oE '[0-9]+' | head -1)
  local res
  res=$(adb -s "$dev" shell wm size 2>/dev/null | grep -i "Physical size" | grep -oE '[0-9]+x[0-9]+' | head -1)
  w=$(echo "$res" | cut -d x -f1)
  h=$(echo "$res" | cut -d x -f2)
  emit_json "{\"connected\":\"$connected\",\"ip\":\"$ip\",\"model\":\"$model\",\"battery\":\"$battery\",\"w\":\"$w\",\"h\":\"$h\"}"
}

# shift out --serial S pairs from the argument list, echoing the serial
take_serial() {
  local serial=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --serial) serial="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "$serial"
}

cmd_status() {
  adb start-server >/dev/null 2>&1
  local serial; serial=$(take_serial "$@")
  local target="$serial"
  [ -z "$target" ] && target=$(any_device)
  [ -z "$target" ] && { emit_json '{"connected":"none","ip":"","model":"","battery":""}'; return; }
  local transport="usb"; case "$target" in *:*) transport="wifi";; esac
  local ip="$target"; [ "$transport" = "wifi" ] && ip="${target%:*}"
  emit_status_json "$transport" "$ip" "$target"
}

cmd_connect() {
  local mode="usb" ip=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wifi) mode="wifi" ;;
      --ip)   ip="$2"; shift ;;
    esac
    shift
  done
  adb start-server >/dev/null 2>&1

  if [ "$mode" = "wifi" ]; then
    [ -z "$ip" ] && ip=$(cfg_get wifi_ip "")
    [ -z "$ip" ] && { emit_json '{"connected":"none","error":"WiFi IP required"}'; return; }
    cfg_set wifi_ip "$ip"
    if adb connect "${ip}:${ADB_PORT}" 2>&1 | grep -qi connected; then
      cmd_status; return
    fi
    # Fallback: enable TCP/IP over a plugged-in USB device, then connect.
    local u; u=$(usb_device)
    if [ -n "$u" ]; then
      adb -s "$u" tcpip "$ADB_PORT" >/dev/null 2>&1
      sleep 2
      adb connect "${ip}:${ADB_PORT}" >/dev/null 2>&1
    fi
    cmd_status; return
  fi

  # USB mode (default): require a USB device.
  local u; u=$(usb_device)
  if [ -n "$u" ]; then cmd_status; return; fi
  # If WiFi is already up, report it instead of failing.
  local w; w=$(wifi_device)
  if [ -n "$w" ]; then cmd_status; return; fi
  emit_json '{"connected":"none","error":"No USB device detected"}'
}

cmd_wake() {
  local serial; serial=$(take_serial "$@")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo "{\"ok\":false}"; return; }
  adb -s "$dev" shell input keyevent KEYCODE_WAKEUP 2>/dev/null
  echo "{\"ok\":true}"
}

cmd_disconnect() {
  adb disconnect >/dev/null 2>&1
  pkill -x scrcpy >/dev/null 2>&1 || true
  echo "{\"ok\":true}"
}

cmd_preview() {
  local out="$1"; shift
  local serial; serial=$(take_serial "$@")
  adb start-server >/dev/null 2>&1
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo "{\"ok\":false}"; exit 1; }
  local tmp="${out}.new"
  if ! timeout 6 adb -s "$dev" exec-out screencap -p > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "{\"ok\":false}"; exit 1
  fi
  # Only replace the image when it actually changed, to avoid preview flicker.
  if [ -s "$out" ] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    echo "{\"ok\":true,\"changed\":false}"
    exit 3
  fi
  mv -f "$tmp" "$out"
  echo "{\"ok\":true,\"changed\":true}"
}

cmd_input() {
  local key="$1"; shift
  local serial; serial=$(take_serial "$@")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo "{\"ok\":false}"; exit 1; }
  adb -s "$dev" shell input keyevent "$key" 2>/dev/null
  echo "{\"ok\":true}"
}

cmd_swipe() {
  local x1="$1" y1="$2" x2="$3" y2="$4" dur="$5"; shift 5
  local serial; serial=$(take_serial "$@")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo "{\"ok\":false}"; exit 1; }
  adb -s "$dev" shell input swipe "$x1" "$y1" "$x2" "$y2" "$dur" 2>/dev/null
  echo "{\"ok\":true}"
}

cmd_save() {
  local dest="${1:-$HOME/Pictures/omadroid-$(date +%Y%m%d-%H%M%S).png}"
  [ -f "$PREVIEW_FILE" ] || { echo "{\"ok\":false,\"error\":\"no preview yet\"}"; exit 1; }
  mkdir -p "$(dirname "$dest")"
  cp "$PREVIEW_FILE" "$dest"
  echo "{\"ok\":true,\"path\":\"$dest\"}"
}

cmd_open() {
  local mode="usb" ip="" max="1080" serial=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wifi) mode="wifi" ;;
      --ip)   ip="$2"; shift ;;
      --max-size) max="$2"; shift ;;
      --serial) serial="$2"; shift ;;
    esac
    shift
  done
  [ -z "$ip" ] && ip=$(cfg_get wifi_ip "")
  [ -z "$max" ] && max=$(cfg_get max_size 1080)

  # A specific device is selected: target it directly (works for USB and WiFi serials).
  if [ -n "$serial" ]; then
    local args=("-s" "$serial" "--video-bit-rate" "16M" "--max-fps" "60" "--window-title" "Omadroid")
    [ -n "$max" ] && [ "$max" != "0" ] && args+=("--max-size" "$max")
    [ -n "${SCRCPY_OPTS:-}" ] && args+=($SCRCPY_OPTS)
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo "{\"launched\":true}"
    return
  fi

  # Auto-detect transport when not forced by a selected serial.
  local u; u=$(usb_device)
  local w; w=$(wifi_device)
  local args=("--video-bit-rate" "16M" "--max-fps" "60" "--window-title" "Omadroid")
  [ -n "$max" ] && [ "$max" != "0" ] && args+=("--max-size" "$max")
  [ -n "${SCRCPY_OPTS:-}" ] && args+=($SCRCPY_OPTS)

  if { [ "$mode" != "wifi" ] || [ -z "$w" ]; } && [ -n "$u" ]; then
    args=("-s" "$u" "${args[@]}")
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo "{\"launched\":true}"; return
  fi
  if [ -n "$w" ]; then
    args=("-s" "$w" "${args[@]}")
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo "{\"launched\":true}"; return
  fi
  if [ "$mode" = "wifi" ] && [ -n "$ip" ]; then
    args+=("--tcpip=${ip}:${ADB_PORT}")
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo "{\"launched\":true}"; return
  fi
  echo "{\"error\":\"No device detected (connect USB or set WiFi IP)\"}"
  exit 1
}

cmd_devices() {
  adb start-server >/dev/null 2>&1
  local raw out="[" first=1 line serial transport model
  raw=$(adb devices -l 2>/dev/null | awk 'NR>1 && $2=="device"')
  while read -r line; do
    [ -z "$line" ] && continue
    serial=$(echo "$line" | awk '{print $1}')
    case "$serial" in
      *:*) transport="wifi" ;;
      *)   transport="usb" ;;
    esac
    model=$(echo "$line" | grep -oE 'model:[^ ]+' | head -1 | sed 's/model://')
    [ "$first" -eq 0 ] && out="$out,"
    first=0
    out="$out{\"serial\":\"$serial\",\"transport\":\"$transport\",\"name\":\"$model\"}"
  done <<< "$raw"
  out="$out]"
  echo "$out"
  printf '%s' "$out" > "$DEVICES_FILE"
}

cmd_config() {
  local sub="$1"; shift
  case "$sub" in
    dump)
      mkdir -p "$CONFIG_DIR"
      {
        echo "wifi_ip=$(cfg_get wifi_ip "")"
        echo "max_size=$(cfg_get max_size 1080)"
        echo "mode=$(cfg_get mode usb)"
      } > "$CONFIG_FILE"
      cat "$CONFIG_FILE"
      ;;
    set)
      local key="$1" val="$2"
      cfg_set "$key" "$val"
      ;;
  esac
}

case "${1:-status}" in
  status)     shift; cmd_status "$@" ;;
  connect)    shift; cmd_connect "$@" ;;
  wake)       shift; cmd_wake "$@" ;;
  disconnect) cmd_disconnect ;;
  open)       shift; cmd_open "$@" ;;
  preview)    shift; cmd_preview "$@" ;;
  devices)    cmd_devices ;;
  input)      shift; cmd_input "$@" ;;
  swipe)      shift; cmd_swipe "$@" ;;
  save)       shift; cmd_save "$@" ;;
  config)     shift; cmd_config "$@" ;;
  *)          echo "{\"error\":\"unknown command\"}"; exit 1 ;;
esac
