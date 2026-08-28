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
#   brightness [up|down|set N]       -> adjust screen brightness (0-255)
#   sysinfo [--serial S]             -> JSON {ram_*, cpu_load, storage_free, ssid, rssi}
#   toggles [--serial S]             -> JSON {wifi, bt, data, airplane} (bool)
#   toggle <wifi|bt|data|airplane>   -> flip a connectivity setting
#   config dump                      -> key=value lines (wifi_ip, max_size, mode)
#   config set <k> <v>               -> persist a setting
#
# Security: USB is the default transport. WiFi is opt-in and only used when
# the user explicitly selects the WiFi mode (and provides the phone IP).
# Runtime state lives only in a private per-user directory; all writes are
# atomic and the device-supplied identifiers/values are validated and escaped.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB_PORT="${ADB_PORT:-5555}"
ADB_TIMEOUT=15
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
CONFIG_FILE="$CONFIG_DIR/omadroid.conf"

# Per-user private runtime dir. XDG_RUNTIME_DIR is unique per user and 0700;
# we require it and refuse to fall back to a shared location.
RUNTIME_BASE="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required and unset}"
OMA_DIR="$RUNTIME_BASE/omadroid"

# Create and verify the runtime dir is a private, user-owned, non-symlink dir.
if [ ! -d "$OMA_DIR" ]; then
  mkdir -m 0700 "$OMA_DIR" 2>/dev/null || { echo '{"error":"cannot create runtime dir"}' >&2; exit 1; }
fi
if [ -L "$OMA_DIR" ] \
   || [ "$(stat -c '%u' "$OMA_DIR" 2>/dev/null)" != "$(id -u)" ] \
   || [ "$(stat -c '%A' "$OMA_DIR" 2>/dev/null | cut -c6)" != "-" ] \
   || [ "$(stat -c '%A' "$OMA_DIR" 2>/dev/null | cut -c9)" != "-" ]; then
  echo '{"error":"insecure runtime dir"}' >&2
  exit 1
fi

STATE_FILE="$OMA_DIR/omadroid-state.json"
DEVICES_FILE="$OMA_DIR/omadroid-devices.json"
PREVIEW_FILE="$OMA_DIR/omadroid-preview.png"
SYSINFO_FILE="$OMA_DIR/omadroid-sysinfo.json"
TOGGLES_FILE="$OMA_DIR/omadroid-toggles.json"

# ── helpers ──────────────────────────────────────────────────────────────────
adbw() { timeout "$ADB_TIMEOUT" adb "$@"; }

atomic_write() {
  local dest="$1" tmp
  tmp=$(mktemp "$OMA_DIR/.tmp.XXXXXX") || return 1
  chmod 0600 "$tmp" 2>/dev/null
  cat > "$tmp"
  mv -f "$tmp" "$dest"
}

out_json() {
  printf '%s' "$2"
  printf '%s' "$2" | atomic_write "$1"
}

jstr() {
  local s="$1"
  s=${s:0:256}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  printf '"%s"' "$s"
}

valid_serial() {
  [ ${#1} -le 64 ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9._:/-]+$ ]] || return 1
  return 0
}

valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$ ]] || return 1
  local o1 o2 o3 o4
  IFS=. read -r o1 o2 o3 o4 _ <<< "${1%%:*}"
  for o in "$o1" "$o2" "$o3" "$o4"; do [ "$o" -le 255 ] || return 1; done
  return 0
}

coerce_serial() {
  local s="$1"
  valid_serial "$s" && [ -n "$s" ] && printf '%s' "$s" || printf ''
}

# ── config helpers ────────────────────────────────────────────────────────────
cfg_get() {
  local key="$1" def="$2" val=""
  [ -f "$CONFIG_FILE" ] && val=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
  printf '%s' "${val:-$def}"
}

cfg_set() {
  local key="$1" val="$2"
  case "$key" in
    wifi_ip)  valid_ip "$val" || return 1 ;;
    max_size) [[ "$val" =~ ^[0-9]{1,5}$ ]] || return 1 ;;
    mode)     [ "$val" = "usb" ] || [ "$val" = "wifi" ] || return 1 ;;
    *)        return 1 ;;
  esac
  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ] && grep -qE "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONFIG_FILE"
  fi
}

# ── device detection ────────────────────────────────────────────────────────────
usb_device() {
  adbw devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -v ':' | awk '{print $1}' | grep -E '^[A-Za-z0-9._:/-]+$' | head -1
}
wifi_device() {
  adbw devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep ':' | awk '{print $1}' | grep -E '^[A-Za-z0-9._:/-]+$' | head -1
}
any_device() {
  local u w
  u=$(usb_device); [ -n "$u" ] && { printf '%s' "$u"; return; }
  w=$(wifi_device); [ -n "$w" ] && { printf '%s' "$w"; return; }
  printf ''
}

take_serial() {
  local serial=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --serial) serial="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s' "$serial"
}

emit_status_json() {
  local connected="$1" ip="$2" dev="$3" model="" battery="" w="" h=""
  [ -z "$dev" ] && dev="$ip"
  [ "$connected" = "wifi" ] && dev="$ip:$ADB_PORT"
  if [ -n "$dev" ] && valid_serial "$dev"; then
    model=$(adbw -s "$dev" shell getprop ro.product.model 2>/dev/null | head -c 128 | tr -d '\r')
    battery=$(adbw -s "$dev" shell dumpsys battery 2>/dev/null | grep -i "level:" | grep -oE '[0-9]+' | head -1)
    local res
    res=$(adbw -s "$dev" shell wm size 2>/dev/null | grep -i "Physical size" | grep -oE '[0-9]+x[0-9]+' | head -1)
    w=$(printf '%s' "$res" | cut -d x -f1 | head -c 8)
    h=$(printf '%s' "$res" | cut -d x -f2 | head -c 8)
  fi
  local json
  json=$(printf '{"connected":%s,"ip":%s,"model":%s,"battery":%s,"w":%s,"h":%s}' \
    "$(jstr "$connected")" "$(jstr "$ip")" "$(jstr "$model")" "$(jstr "$battery")" "$(jstr "$w")" "$(jstr "$h")")
  out_json "$STATE_FILE" "$json"
}

cmd_status() {
  adbw start-server >/dev/null 2>&1
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  local target="$serial"
  [ -z "$target" ] && target=$(any_device)
  [ -z "$target" ] && { out_json "$STATE_FILE" '{"connected":"none","ip":"","model":"","battery":""}'; return; }
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
  adbw start-server >/dev/null 2>&1

  if [ "$mode" = "wifi" ]; then
    [ -z "$ip" ] && ip=$(cfg_get wifi_ip "")
    [ -z "$ip" ] && { out_json "$STATE_FILE" '{"connected":"none","error":"WiFi IP required"}'; return; }
    valid_ip "$ip" || { out_json "$STATE_FILE" '{"connected":"none","error":"Invalid WiFi IP"}'; return; }
    cfg_set wifi_ip "$ip"
    if adbw connect "${ip}:${ADB_PORT}" 2>&1 | grep -qi connected; then
      cmd_status; return
    fi
    local u; u=$(usb_device)
    if [ -n "$u" ]; then
      adbw -s "$u" tcpip "$ADB_PORT" >/dev/null 2>&1
      sleep 2
      adbw connect "${ip}:${ADB_PORT}" >/dev/null 2>&1
    fi
    cmd_status; return
  fi

  local u; u=$(usb_device)
  [ -n "$u" ] && { cmd_status; return; }
  local w; w=$(wifi_device)
  [ -n "$w" ] && { cmd_status; return; }
  out_json "$STATE_FILE" '{"connected":"none","error":"No USB device detected"}'
}

cmd_wake() {
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo '{"ok":false}'; return; }
  adbw -s "$dev" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
  echo '{"ok":true}'
}

cmd_disconnect() {
  adbw disconnect >/dev/null 2>&1
  pkill -x scrcpy >/dev/null 2>&1 || true
  echo '{"ok":true}'
}

cmd_preview() {
  local out="$1"; shift
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  adbw start-server >/dev/null 2>&1
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo '{"ok":false}'; exit 1; }
  local tmp="${OMA_DIR}/.preview.$$.tmp"
  if ! adbw -s "$dev" exec-out screencap -p > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo '{"ok":false}'; exit 1
  fi
  local sig sz
  sig=$(head -c 8 "$tmp" | od -An -tx1 | tr -d ' \n')
  sz=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
  if [ "$sig" != "89504e470d0a1a0a" ] || [ "$sz" -gt 20971520 ] || [ "$sz" -eq 0 ]; then
    rm -f "$tmp"
    echo '{"ok":false}'; exit 1
  fi
  if [ -s "$out" ] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    echo '{"ok":true,"changed":false}'; exit 3
  fi
  mv -f "$tmp" "$out"
  echo '{"ok":true,"changed":true}'
}

cmd_input() {
  local key="$1"; shift
  [[ "$key" =~ ^[A-Za-z_]+$ ]] || { echo '{"ok":false}'; exit 1; }
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo '{"ok":false}'; exit 1; }
  adbw -s "$dev" shell input keyevent "$key" >/dev/null 2>&1
  echo '{"ok":true}'
}

cmd_swipe() {
  local x1="$1" y1="$2" x2="$3" y2="$4" dur="$5"; shift 5
  for n in "$x1" "$y1" "$x2" "$y2" "$dur"; do
    [[ "$n" =~ ^-?[0-9]+$ ]] || { echo '{"ok":false}'; exit 1; }
  done
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo '{"ok":false}'; exit 1; }
  adbw -s "$dev" shell input swipe "$x1" "$y1" "$x2" "$y2" "$dur" >/dev/null 2>&1
  echo '{"ok":true}'
}

cmd_save() {
  local dest="${1:-$HOME/Pictures/omadroid-$(date +%Y%m%d-%H%M%S).png}"
  [ -f "$PREVIEW_FILE" ] || { echo '{"ok":false,"error":"no preview yet"}'; exit 1; }
  mkdir -p "$(dirname "$dest")"
  cp "$PREVIEW_FILE" "$dest"
  command -v notify-send >/dev/null 2>&1 && notify-send "Omadroid" "Screenshot saved to $dest"
  echo "{\"ok\":true,\"path\":$(jstr "$dest")}"
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
  serial=$(coerce_serial "$serial")
  [[ "$max" =~ ^[0-9]{1,4}$ ]] || max=1080
  [ -z "$ip" ] && ip=$(cfg_get wifi_ip "")

  if [ -n "$serial" ]; then
    local args=("-s" "$serial" "--video-bit-rate" "16M" "--max-fps" "60" "--window-title" "Omadroid")
    [ "$max" != "0" ] && args+=("--max-size" "$max")
    [ -n "${SCRCPY_OPTS:-}" ] && args+=($SCRCPY_OPTS)
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo '{"launched":true}'; return
  fi

  local u; u=$(usb_device)
  local w; w=$(wifi_device)
  local args=("--video-bit-rate" "16M" "--max-fps" "60" "--window-title" "Omadroid")
  [ "$max" != "0" ] && args+=("--max-size" "$max")
  [ -n "${SCRCPY_OPTS:-}" ] && args+=($SCRCPY_OPTS)

  if { [ "$mode" != "wifi" ] || [ -z "$w" ]; } && [ -n "$u" ]; then
    args=("-s" "$u" "${args[@]}")
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo '{"launched":true}'; return
  fi
  if [ -n "$w" ]; then
    args=("-s" "$w" "${args[@]}")
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo '{"launched":true}'; return
  fi
  if [ "$mode" = "wifi" ] && [ -n "$ip" ] && valid_ip "$ip"; then
    args+=("--tcpip=${ip}:${ADB_PORT}")
    setsid scrcpy "${args[@]}" >/dev/null 2>&1 &
    echo '{"launched":true}'; return
  fi
  echo '{"error":"No device detected (connect USB or set WiFi IP)"}'
  exit 1
}

cmd_devices() {
  adbw start-server >/dev/null 2>&1
  local raw out="[" first=1 line serial transport model
  raw=$(adbw devices -l 2>/dev/null | awk 'NR>1 && $2=="device"')
  while read -r line; do
    [ -z "$line" ] && continue
    serial=$(printf '%s' "$line" | awk '{print $1}')
    valid_serial "$serial" || continue
    case "$serial" in
      *:*) transport="wifi" ;;
      *)   transport="usb" ;;
    esac
    model=$(printf '%s' "$line" | grep -oE 'model:[^ ]+' | head -1 | sed 's/model://')
    [ "$first" -eq 0 ] && out="$out,"
    first=0
    out="$out{\"serial\":$(jstr "$serial"),\"transport\":$(jstr "$transport"),\"name\":$(jstr "$model")}"
  done <<< "$raw"
  out="$out]"
  out_json "$DEVICES_FILE" "$out"
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
      cfg_set "$key" "$val" || { echo "invalid config"; exit 1; }
      ;;
  esac
}

cmd_brightness() {
  local action="${1:-up}" setval="${2:-}" serial
  serial=$(coerce_serial "$(take_serial "$@")")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo '{"ok":false}'; exit 1; }
  local cur new
  cur=$(adbw -s "$dev" shell settings get system screen_brightness 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[0-9]+' | head -1)
  cur=${cur:-128}
  new=$cur
  case "$action" in
    up)   new=$((cur + 25)) ;;
    down) new=$((cur - 25)) ;;
    set)  new=${setval:-$cur} ;;
    *)    new=$cur ;;
  esac
  [[ "$new" =~ ^[0-9]+$ ]] || new=128
  [ "$new" -lt 5 ] && new=5
  [ "$new" -gt 255 ] && new=255
  adbw -s "$dev" shell settings put system screen_brightness "$new" >/dev/null 2>&1
  echo "{\"level\":$new}"
}

cmd_sysinfo() {
  adbw start-server >/dev/null 2>&1
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  if [ -z "$dev" ]; then
    out_json "$SYSINFO_FILE" '{"ram_used":0,"ram_total":0,"cpu_load":0,"storage_free":0,"storage_total":0,"ssid":"","rssi":""}'
    return
  fi
  local out ram_total ram_avail ram_used_gb ram_total_gb cpu_load ssid rssi diskline storage_free_k storage_total_k
  out=$(adbw -s "$dev" shell "echo MEM; grep -E '^MemTotal|^MemAvailable' /proc/meminfo; echo LOAD; cat /proc/loadavg; echo CPU; top -n 1 2>/dev/null | grep -E '[0-9]+%cpu'; echo DISK; dumpsys diskstats 2>/dev/null | grep -i 'Data-Free:'; echo WIFI; dumpsys wifi 2>/dev/null | grep -E 'SSID:'" 2>/dev/null | head -c 65536 | tr -d '\r')

  ram_total=$(printf '%s' "$out" | awk '/^MEM$/{f=1;next} f&&/MemTotal/{print $2;f=0}')
  ram_avail=$(printf '%s' "$out" | awk '/^MEM$/{f=1;next} f&&/MemAvailable/{print $2}')
  diskline=$(printf '%s' "$out" | awk '/^DISK$/{f=1;next} f{print;f=0}')
  storage_free_k=$(printf '%s' "$diskline" | sed -n 's/.*Data-Free:[[:space:]]*\([0-9]*\)K.*/\1/p')
  storage_total_k=$(printf '%s' "$diskline" | sed -n 's/.*\/[[:space:]]*\([0-9]*\)K.*/\1/p')

  ram_total_gb=$(awk -v t="$ram_total" 'BEGIN{printf "%.1f", t/1048576}')
  ram_used_gb=$(awk -v t="$ram_total" -v a="$ram_avail" 'BEGIN{printf "%.1f", (t-a)/1048576}')
  cpu_load=$(printf '%s' "$out" | awk '/^CPU$/{f=1;next} f&&/%cpu/{match($0,/([0-9]+)%cpu/,a); mt=a[1]; match($0,/([0-9]+)%idle/,b); id=b[1]; if(mt>0) printf "%d", (mt-id)*100/mt+0.5; f=0}')
  storage_free_gb=$(awk -v f="$storage_free_k" 'BEGIN{printf "%.1f", f/1048576}')
  storage_total_gb=$(awk -v f="$storage_total_k" 'BEGIN{printf "%.1f", f/1048576}')

  ssid=$(printf '%s' "$out" | sed -n 's/.*SSID:[[:space:]]*"\([^"]*\)".*/\1/p' | head -c 64 | head -1)
  rssi=$(printf '%s' "$out" | grep -oE 'mRssi=-?[0-9]+' | head -1 | sed 's/mRssi=//' | head -c 8)

  local json
  json=$(printf '{"ram_used":%s,"ram_total":%s,"cpu_load":%s,"storage_free":%s,"storage_total":%s,"ssid":%s,"rssi":%s}' \
    "$(jstr "$ram_used_gb")" "$(jstr "$ram_total_gb")" "$(jstr "$cpu_load")" "$(jstr "$storage_free_gb")" "$(jstr "$storage_total_gb")" "$(jstr "$ssid")" "$(jstr "$rssi")")
  out_json "$SYSINFO_FILE" "$json"
}

cmd_toggles() {
  adbw start-server >/dev/null 2>&1
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  if [ -z "$dev" ]; then
    out_json "$TOGGLES_FILE" '{"wifi":false,"bt":false,"data":false,"airplane":false}'
    return
  fi
  local wifi bt data airplane
  wifi=$(adbw -s "$dev" shell settings get global wifi_on 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
  bt=$(adbw -s "$dev" shell settings get global bluetooth_on 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
  data=$(adbw -s "$dev" shell settings get global mobile_data 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
  airplane=$(adbw -s "$dev" shell settings get global airplane_mode_on 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
  [ -z "$wifi" ] && wifi=0
  [ -z "$bt" ] && bt=0
  [ -z "$data" ] && data=0
  [ -z "$airplane" ] && airplane=0
  local json
  json=$(printf '{"wifi":%s,"bt":%s,"data":%s,"airplane":%s}' \
    "$([ "$wifi" = "1" ] && echo true || echo false)" \
    "$([ "$bt" = "1" ] && echo true || echo false)" \
    "$([ "$data" = "1" ] && echo true || echo false)" \
    "$([ "$airplane" = "1" ] && echo true || echo false)")
  out_json "$TOGGLES_FILE" "$json"
}

cmd_toggle() {
  local what="$1"; shift
  case "$what" in
    wifi|bt|data|airplane) ;;
    *) out_json "$TOGGLES_FILE" '{"ok":false,"error":"unknown toggle"}'; exit 1 ;;
  esac
  adbw start-server >/dev/null 2>&1
  local serial; serial=$(coerce_serial "$(take_serial "$@")")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { out_json "$TOGGLES_FILE" '{"ok":false}'; exit 1; }
  local s
  case "$what" in
    wifi)
      s=$(adbw -s "$dev" shell settings get global wifi_on 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then adbw -s "$dev" shell svc wifi disable >/dev/null 2>&1
      else adbw -s "$dev" shell svc wifi enable >/dev/null 2>&1; fi ;;
    bt)
      s=$(adbw -s "$dev" shell settings get global bluetooth_on 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then adbw -s "$dev" shell svc bluetooth disable >/dev/null 2>&1
      else adbw -s "$dev" shell svc bluetooth enable >/dev/null 2>&1; fi ;;
    data)
      s=$(adbw -s "$dev" shell settings get global mobile_data 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then adbw -s "$dev" shell svc data disable >/dev/null 2>&1
      else adbw -s "$dev" shell svc data enable >/dev/null 2>&1; fi ;;
    airplane)
      s=$(adbw -s "$dev" shell settings get global airplane_mode_on 2>/dev/null | head -c 16 | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then
        adbw -s "$dev" shell settings put global airplane_mode_on 0 >/dev/null 2>&1
        adbw -s "$dev" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
      else
        adbw -s "$dev" shell settings put global airplane_mode_on 1 >/dev/null 2>&1
        adbw -s "$dev" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
      fi ;;
  esac
  cmd_toggles --serial "$dev"
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
  brightness) shift; cmd_brightness "$@" ;;
  sysinfo)    shift; cmd_sysinfo "$@" ;;
  toggles)    shift; cmd_toggles "$@" ;;
  toggle)     shift; cmd_toggle "$@" ;;
  config)     shift; cmd_config "$@" ;;
  *)          echo '{"error":"unknown command"}'; exit 1 ;;
esac
