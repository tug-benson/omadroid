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
#   record [start|stop|status]       -> screenrecord to ~/Videos
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
SYSINFO_FILE="${OMADROID_SYSINFO:-/tmp/omadroid-sysinfo.json}"
TOGGLES_FILE="${OMADROID_TOGGLES:-/tmp/omadroid-toggles.json}"
REC_FILE="${OMADROID_REC:-/tmp/omadroid-record.json}"
REC_PID_FILE="/tmp/omadroid-record.pid"
REC_REMOTE="/sdcard/omadroid_recording.mp4"

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
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Omadroid" "Screenshot saved to $dest"
  fi
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

cmd_brightness() {
  local action="${1:-up}" setval="${2:-}" serial
  serial=$(take_serial "$@")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { echo '{"ok":false}'; exit 1; }
  local cur new
  cur=$(adb -s "$dev" shell settings get system screen_brightness 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+' | head -1)
  cur=${cur:-128}
  new=$cur
  case "$action" in
    up)   new=$((cur + 25)) ;;
    down) new=$((cur - 25)) ;;
    set)  new=${setval:-$cur} ;;
  esac
  [ "$new" -lt 5 ] && new=5
  [ "$new" -gt 255 ] && new=255
  adb -s "$dev" shell settings put system screen_brightness "$new" >/dev/null 2>&1
  echo "{\"level\":$new}"
}

cmd_sysinfo() {
  adb start-server >/dev/null 2>&1
  local serial; serial=$(take_serial "$@")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  if [ -z "$dev" ]; then
    printf '{"ram_used":0,"ram_total":0,"cpu_load":0,"storage_free":0,"storage_total":0,"ssid":"","rssi":""}' > "$SYSINFO_FILE"
    return
  fi
  local out ram_total ram_avail ram_used_gb ram_total_gb nproc load1 storage_free_gb storage_total_gb cpu_load ssid rssi diskline storage_free_k storage_total_k
  out=$(adb -s "$dev" shell "echo MEM; grep -E '^MemTotal|^MemAvailable' /proc/meminfo; echo LOAD; cat /proc/loadavg; echo CPU; top -n 1 2>/dev/null | grep -E '[0-9]+%cpu'; echo DISK; dumpsys diskstats 2>/dev/null | grep -i 'Data-Free:'; echo WIFI; dumpsys wifi 2>/dev/null | grep -E 'SSID:'" 2>/dev/null | tr -d '\r')

  ram_total=$(echo "$out" | awk '/^MEM$/{f=1;next} f&&/MemTotal/{print $2;f=0}')
  ram_avail=$(echo "$out" | awk '/^MEM$/{f=1;next} f&&/MemAvailable/{print $2}')
  diskline=$(echo "$out" | awk '/^DISK$/{f=1;next} f{print;f=0}')
  storage_free_k=$(echo "$diskline" | sed -n 's/.*Data-Free:[[:space:]]*\([0-9]*\)K.*/\1/p')
  storage_total_k=$(echo "$diskline" | sed -n 's/.*\/[[:space:]]*\([0-9]*\)K.*/\1/p')

  ram_total_gb=$(awk -v t="$ram_total" 'BEGIN{printf "%.1f", t/1048576}')
  ram_used_gb=$(awk -v t="$ram_total" -v a="$ram_avail" 'BEGIN{printf "%.1f", (t-a)/1048576}')
  cpu_load=$(echo "$out" | awk '/^CPU$/{f=1;next} f&&/%cpu/{match($0,/([0-9]+)%cpu/,a); mt=a[1]; match($0,/([0-9]+)%idle/,b); id=b[1]; if(mt>0) printf "%d", (mt-id)*100/mt+0.5; f=0}')
  storage_free_gb=$(awk -v f="$storage_free_k" 'BEGIN{printf "%.1f", f/1048576}')
  storage_total_gb=$(awk -v f="$storage_total_k" 'BEGIN{printf "%.1f", f/1048576}')

  ssid=$(echo "$out" | sed -n 's/.*SSID:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  rssi=$(echo "$out" | grep -oE 'mRssi=-?[0-9]+' | head -1 | sed 's/mRssi=//')

  local json="{\"ram_used\":$ram_used_gb,\"ram_total\":$ram_total_gb,\"cpu_load\":$cpu_load,\"storage_free\":$storage_free_gb,\"storage_total\":$storage_total_gb,\"ssid\":\"$ssid\",\"rssi\":\"$rssi\"}"
  printf '%s' "$json" > "$SYSINFO_FILE"
}

cmd_toggles() {
  adb start-server >/dev/null 2>&1
  local serial; serial=$(take_serial "$@")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  if [ -z "$dev" ]; then
    printf '{"wifi":false,"bt":false,"data":false,"airplane":false}' > "$TOGGLES_FILE"
    return
  fi
  local wifi bt data airplane
  wifi=$(adb -s "$dev" shell settings get global wifi_on 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
  bt=$(adb -s "$dev" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
  data=$(adb -s "$dev" shell settings get global mobile_data 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
  airplane=$(adb -s "$dev" shell settings get global airplane_mode_on 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
  [ -z "$wifi" ] && wifi=0
  [ -z "$bt" ] && bt=0
  [ -z "$data" ] && data=0
  [ -z "$airplane" ] && airplane=0
  local json="{\"wifi\":$([ "$wifi" = "1" ] && echo true || echo false),\"bt\":$([ "$bt" = "1" ] && echo true || echo false),\"data\":$([ "$data" = "1" ] && echo true || echo false),\"airplane\":$([ "$airplane" = "1" ] && echo true || echo false)}"
  printf '%s' "$json" > "$TOGGLES_FILE"
}

cmd_toggle() {
  local what="$1"; shift
  adb start-server >/dev/null 2>&1
  local serial; serial=$(take_serial "$@")
  local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
  [ -z "$dev" ] && { printf '{"ok":false}' > "$TOGGLES_FILE"; exit 1; }
  local s
  case "$what" in
    wifi)
      s=$(adb -s "$dev" shell settings get global wifi_on 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then adb -s "$dev" shell svc wifi disable >/dev/null 2>&1
      else adb -s "$dev" shell svc wifi enable >/dev/null 2>&1; fi ;;
    bt)
      s=$(adb -s "$dev" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then adb -s "$dev" shell svc bluetooth disable >/dev/null 2>&1
      else adb -s "$dev" shell svc bluetooth enable >/dev/null 2>&1; fi ;;
    data)
      s=$(adb -s "$dev" shell settings get global mobile_data 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then adb -s "$dev" shell svc data disable >/dev/null 2>&1
      else adb -s "$dev" shell svc data enable >/dev/null 2>&1; fi ;;
    airplane)
      s=$(adb -s "$dev" shell settings get global airplane_mode_on 2>/dev/null | tr -d '\r' | grep -oE '[01]' | head -1)
      if [ "$s" = "1" ]; then
        adb -s "$dev" shell settings put global airplane_mode_on 0 >/dev/null 2>&1
        adb -s "$dev" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
      else
        adb -s "$dev" shell settings put global airplane_mode_on 1 >/dev/null 2>&1
        adb -s "$dev" shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
      fi ;;
    *) printf '{"ok":false,"error":"unknown toggle"}' > "$TOGGLES_FILE"; exit 1 ;;
  esac
  cmd_toggles --serial "$dev"
}

cmd_record() {
  local sub="${1:-status}"; shift 2>/dev/null || true
  case "$sub" in
    start)
      local serial; serial=$(take_serial "$@")
      local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
      [ -z "$dev" ] && { printf '{"recording":false,"error":"no device"}' > "$REC_FILE"; exit 1; }
      [ -f "$REC_PID_FILE" ] && { printf '{"recording":true,"error":"already recording"}' > "$REC_FILE"; exit 1; }
      # Stop any leftover recording on the device and clear the old file so a
      # fresh capture can start cleanly.
      adb -s "$dev" shell 'pkill -INT screenrecord 2>/dev/null || true' >/dev/null 2>&1
      sleep 1
      adb -s "$dev" shell rm -f "$REC_REMOTE" >/dev/null 2>&1
      adb -s "$dev" shell screenrecord "$REC_REMOTE" >/dev/null 2>&1 &
      echo $! > "$REC_PID_FILE"
      printf '{"recording":true}' > "$REC_FILE"
      ;;
    stop)
      local serial; serial=$(take_serial "$@")
      local dev="$serial"; [ -z "$dev" ] && dev=$(any_device)
      if [ -n "$dev" ]; then
        # Signal the on-device screenrecord directly so it flushes the moov
        # atom and finalizes the file (killing the local adb alone does not).
        adb -s "$dev" shell 'pkill -INT screenrecord 2>/dev/null || kill -INT $(pidof screenrecord) 2>/dev/null' >/dev/null 2>&1 || true
        sleep 2
      fi
      if [ -f "$REC_PID_FILE" ]; then
        kill "$(cat "$REC_PID_FILE")" >/dev/null 2>&1 || true
        rm -f "$REC_PID_FILE"
      fi
      local dest="$HOME/Videos/omadroid-$(date +%Y%m%d-%H%M%S).mp4"
      if [ -n "$dev" ]; then
        mkdir -p "$(dirname "$dest")"
        adb -s "$dev" pull "$REC_REMOTE" "$dest" >/dev/null 2>&1 || true
        adb -s "$dev" shell rm -f "$REC_REMOTE" >/dev/null 2>&1 || true
      fi
      if command -v notify-send >/dev/null 2>&1; then
        notify-send "Omadroid" "Recording saved to $dest"
      fi
      printf '{"recording":false,"path":"%s"}' "$dest" > "$REC_FILE"
      ;;
    status)
      if [ -f "$REC_PID_FILE" ] && kill -0 "$(cat "$REC_PID_FILE")" 2>/dev/null; then
        printf '{"recording":true}' > "$REC_FILE"
      else
        rm -f "$REC_PID_FILE"
        printf '{"recording":false}' > "$REC_FILE"
      fi
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
  brightness) shift; cmd_brightness "$@" ;;
  sysinfo)    shift; cmd_sysinfo "$@" ;;
  toggles)    shift; cmd_toggles "$@" ;;
  toggle)     shift; cmd_toggle "$@" ;;
  record)     shift; cmd_record "$@" ;;
  config)     shift; cmd_config "$@" ;;
  *)          echo "{\"error\":\"unknown command\"}"; exit 1 ;;
esac
