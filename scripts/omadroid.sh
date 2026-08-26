#!/usr/bin/env bash
# omadroid.sh — helper for the Omadroid Omarchy plugin
#
# Subcommands:
#   status              -> JSON {connected, ip, model}
#   connect [--wifi] [--ip IP]
#                      -> JSON status (USB first, optional WiFi)
#   wake                -> wake the device screen (keyevent WAKEUP)
#   disconnect          -> drop WiFi ADB + close scrcpy
#   preview <outfile>   -> write a PNG screenshot to <outfile>
#   config dump         -> key=value lines (wifi_ip, max_size, mode)
#   config set <k> <v>  -> persist a setting
#
# Security: USB is the default transport. WiFi is opt-in and only used when
# the user explicitly selects the WiFi mode (and provides the phone IP).

set -u
ADB_PORT="${ADB_PORT:-5555}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
CONFIG_FILE="$CONFIG_DIR/omadroid.conf"
STATE_FILE="${OMADROID_STATE:-/tmp/omadroid-state.json}"

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
  local connected="$1" ip="$2" model="" battery=""
  local dev="$ip"
  [ "$connected" = "wifi" ] && dev="$ip:$ADB_PORT"
  model=$(adb -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
  battery=$(adb -s "$dev" shell dumpsys battery 2>/dev/null | grep -i "level:" | grep -oE '[0-9]+' | head -1)
  emit_json "{\"connected\":\"$connected\",\"ip\":\"$ip\",\"model\":\"$model\",\"battery\":\"$battery\"}"
}

cmd_status() {
  adb start-server >/dev/null 2>&1
  local u w
  u=$(usb_device); w=$(wifi_device)
  if [ -n "$w" ]; then emit_status_json "wifi" "${w%:*}"; return; fi
  if [ -n "$u" ]; then emit_status_json "usb"  "$u"; return; fi
  emit_json '{"connected":"none","ip":"","model":""}'
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
  local dev; dev=$(any_device)
  [ -z "$dev" ] && { echo "{\"ok\":false}"; return; }
  adb -s "$dev" shell input keyevent KEYCODE_WAKEUP 2>/dev/null
  echo "{\"ok\":true}"
}

cmd_disconnect() {
  adb disconnect >/dev/null 2>&1
  pkill -x scrcpy >/dev/null 2>&1 || true
  echo "{\"ok\":true}"
}

cmd_open() {
  local mode="usb" ip="" max="1080"
  while [ $# -gt 0 ]; do
    case "$1" in
      --wifi) mode="wifi" ;;
      --ip)   ip="$2"; shift ;;
      --max-size) max="$2"; shift ;;
    esac
    shift
  done
  [ -z "$ip" ] && ip=$(cfg_get wifi_ip "")
  [ -z "$max" ] && max=$(cfg_get max_size 720)

  local args=("--max-size" "$max" "--video-bit-rate" "16M" "--max-fps" "60" "--window-title" "Omadroid")
  if [ "$mode" = "wifi" ]; then
    [ -z "$ip" ] && { echo "{\"error\":\"WiFi IP required\"}"; exit 1; }
    args+=("--tcpip=${ip}:${ADB_PORT}")
  fi
  # Optional extra scrcpy flags from the environment.
  if [ -n "${SCRCPY_OPTS:-}" ]; then
    # shellcheck disable=SC2206
    args+=($SCRCPY_OPTS)
  fi
  setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
  echo "{\"launched\":true}"
}

cmd_preview() {
  local out="$1"
  adb start-server >/dev/null 2>&1
  local dev; dev=$(any_device)
  [ -z "$dev" ] && { echo "{\"ok\":false}"; exit 1; }
  if adb -s "$dev" exec-out screencap -p > "$out" 2>/dev/null; then
    echo "{\"ok\":true}"
  else
    echo "{\"ok\":false}"; exit 1
  fi
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
  status)     cmd_status ;;
  connect)    shift; cmd_connect "$@" ;;
  wake)       cmd_wake ;;
  disconnect) cmd_disconnect ;;
  open)       shift; cmd_open "$@" ;;
  preview)    cmd_preview "$2" ;;
  config)     shift; cmd_config "$@" ;;
  *)          echo "{\"error\":\"unknown command\"}"; exit 1 ;;
esac
