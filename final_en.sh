#!/usr/bin/env bash
#: scrcpy_pro_v2_fixed_en.sh
#: Translated to English - comments disabled
#: Requirements: adb, scrcpy, qrencode (optional), ping

set -o errexit
set -o pipefail
set -o nounset

CONF="$HOME/.scrcpy_pro_v2.conf"
LOG="$HOME/.scrcpy_pro_v2.log"
TMPPING="/tmp/scrcpy_v2_ping.$$"
TMPFPS="/tmp/scrcpy_v2_fps.$$"
PING_INTERVAL=2

DEFAULT_MAX_FPS=60
DEFAULT_BITRATE="16M"
DEFAULT_MAXSIZE=0
DEFAULT_TURN_SCREEN_OFF="no"
DEFAULT_STAY_AWAKE="yes"
DEFAULT_NO_AUDIO="yes"
DEFAULT_RECORD="no"
DEFAULT_RECORD_PATH="$HOME/scrcpy_record_$(date +%Y%m%d_%H%M%S).mp4"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log(){ echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
ok(){ echo -e "${GREEN}$*${NC}"; }
warn(){ echo -e "${YELLOW}$*${NC}"; }
err(){ echo -e "${RED}$*${NC}"; }

check_deps(){
  local miss=0
  for cmd in adb scrcpy; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Missing required command: $cmd"
      miss=1
    fi
  done
  if ! command -v ping >/dev/null 2>&1; then
    warn "ping command not found; ping will not be displayed"
  fi
  if [ $miss -eq 1 ]; then
    err "Please install missing dependencies and retry."
    return 1
  fi
  return 0
}

load_config(){
  if [ -f "$CONF" ]; then
    source "$CONF"
    ok "Settings loaded: $CONF"
  else
    MAX_FPS=$DEFAULT_MAX_FPS
    BITRATE=$DEFAULT_BITRATE
    MAXSIZE=$DEFAULT_MAXSIZE
    TURN_SCREEN_OFF=$DEFAULT_TURN_SCREEN_OFF
    STAY_AWAKE=$DEFAULT_STAY_AWAKE
    NO_AUDIO=$DEFAULT_NO_AUDIO
    RECORD=$DEFAULT_RECORD
    RECORD_PATH=$DEFAULT_RECORD_PATH
  fi
}

save_config(){
  cat > "$CONF" <<EOF
MAX_FPS=${MAX_FPS}
BITRATE="${BITRATE}"
MAXSIZE=${MAXSIZE}
TURN_SCREEN_OFF="${TURN_SCREEN_OFF}"
STAY_AWAKE="${STAY_AWAKE}"
NO_AUDIO="${NO_AUDIO}"
RECORD="${RECORD}"
RECORD_PATH="${RECORD_PATH}"
EOF
  ok "Settings saved: $CONF"
}

reset_config(){
  rm -f "$CONF"
  ok "Configuration file deleted."
}

get_connected_devices(){
  adb devices | awk 'NR>1 && $2=="device" {print $1}'
}

pick_device_interactive(){
  mapfile -t arr < <(get_connected_devices)
  if [ ${#arr[@]} -eq 0 ]; then
    return 1
  elif [ ${#arr[@]} -eq 1 ]; then
    serial="${arr[0]}"
    return 0
  else
    echo "Connected devices:"
    for i in "${!arr[@]}"; do
      echo "$((i+1))) ${arr[$i]}"
    done
    read -p "Select number: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] ; then
      return 2
    fi
    idx=$((sel-1))
    serial="${arr[$idx]:-}"
    if [ -z "$serial" ]; then
      return 2
    fi
    return 0
  fi
}

usb_to_wifi_connect(){
  mapfile -t usbs < <(adb devices | awk 'NR>1 && $2=="device" && $1 !~ /:/ {print $1}')
  if [ ${#usbs[@]} -eq 0 ]; then
    err "No USB-connected devices found."
    return 1
  fi
  if [ ${#usbs[@]} -gt 1 ]; then
    echo "USB-connected devices:"
    for i in "${!usbs[@]}"; do echo "$((i+1))) ${usbs[$i]}"; done
    read -p "Select (number): " n
    dev=${usbs[$((n-1))]}
  else
    dev=${usbs[0]}
  fi
  ok "Selected USB device: $dev"
  adb -s "$dev" tcpip 5555 >/dev/null 2>&1 || { err "adb tcpip failed"; return 2; }
  sleep 1
  IP=$(adb -s "$dev" shell ip -f inet addr show wlan0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 || true)
  if [ -z "$IP" ]; then
    warn "Could not detect device IP. You will need to enter it manually."
    read -p "Enter phone IP address (e.g. 192.168.1.56): " IP
  fi
  TARGET="${IP}:5555"
  ok "Connecting: $TARGET"
  adb connect "$TARGET" >/dev/null 2>&1 || { err "adb connect failed"; return 3; }
  serial="$TARGET"
  sleep 1
  return 0
}

wireless_pair_connect(){
  local mode="$1"
  if [ "$mode" = "link" ]; then
    read -p "Paste adb:// link: " QRLINK
    IPPAIR=$(echo "$QRLINK" | sed -n 's|adb://\([^?]*\)\?.*|\1|p' || true)
    PAIRCODE=$(echo "$QRLINK" | sed -n 's/.*pairing_code=\([0-9]*\).*/\1/p' || true)
    if [ -z "$IPPAIR" ] || [ -z "$PAIRCODE" ]; then
      err "Failed to parse link."
      return 2
    fi
  else
    read -p "Enter IP and Pair port (e.g. 192.168.1.56:42345): " IPPAIR
    read -p "Enter 6-digit pairing code shown on phone: " PAIRCODE
  fi
  read -p "Connection port (default 5555): " CONPORT
  CONPORT=${CONPORT:-5555}
  iponly=$(echo "$IPPAIR" | cut -d: -f1)
  if command -v ping >/dev/null 2>&1; then
    if ! ping -c1 -W1 "$iponly" >/dev/null 2>&1; then
      warn "Ping failed for: $iponly (connection might fail)"
    fi
  fi
  echo "$PAIRCODE" | adb pair "$IPPAIR" >/dev/null 2>&1 || { err "adb pair failed"; return 3; }
  adb connect "${iponly}:${CONPORT}" >/dev/null 2>&1 || { err "adb connect failed"; return 4; }
  serial="${iponly}:${CONPORT}"
  ok "Wireless connected: $serial"
  return 0
}

start_ping_monitor(){
  ip_only=$(echo "$serial" | cut -d: -f1)
  if [ -z "$ip_only" ] || [[ "$serial" == emulator-* ]]; then
    return 0
  fi
  ( while true; do
      if ping -c1 -W1 "$ip_only" >/dev/null 2>&1; then
        p=$(ping -c1 -W1 "$ip_only" | sed -n '2p' | awk -F'=' '{print $4}' | awk '{print $1}')
        echo "$p" > "$TMPPING"
      else
        echo "timeout" > "$TMPPING"
      fi
      sleep $PING_INTERVAL
    done ) &
  PING_PID=$!
}

start_fps_probe(){
  ( while true; do
      pkg=$(adb shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -oP 'mResumedActivity: ActivityRecord{[^ ]+ \K[^/ ]+' | head -n1 || true)
      if [ -n "$pkg" ]; then
        out=$(adb shell dumpsys gfxinfo "$pkg" 2>/dev/null || true)
        if echo "$out" | grep -qi "Total frames rendered"; then
          echo "$(echo "$out" | grep -m1 -E 'Total frames rendered|Janky frames' || true)" > "$TMPFPS"
        else
          echo "N/A" > "$TMPFPS"
        fi
      else
        echo "N/A" > "$TMPFPS"
      fi
      sleep 2
    done ) &
  FPS_PID=$!
}

cleanup(){
  [ -n "${PING_PID:-}" ] && kill "${PING_PID}" 2>/dev/null || true
  [ -n "${FPS_PID:-}" ] && kill "${FPS_PID}" 2>/dev/null || true
  rm -f "$TMPPING" "$TMPFPS" 2>/dev/null || true
}

trap cleanup EXIT

show_device_info(){
  local s="$1"
  local dev="$s"
  ok "Getting device info..."
  model=$(adb -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "N/A")
  brand=$(adb -s "$dev" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r' || echo "N/A")
  android_v=$(adb -s "$dev" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "N/A")
  echo "────────────────────────────────────────"
  echo -e "Model    : ${brand} ${model}"
  echo -e "Android  : ${android_v}"
  echo -e "Serial   : ${dev}"
  echo "────────────────────────────────────────"
}

if ! check_deps; then
  exit 1
fi

load_config

while true; do
  clear
  echo -e "${BLUE}📱 scrcpy PRO v2 - QR+INFO (EN)${NC}"
  echo "1) Start with saved settings"
  echo "2) Create new settings (can be saved)"
  echo "3) Wireless (QR/link or manual)"
  echo "4) USB -> WiFi (auto)"
  echo "5) Select from connected devices"
  echo "6) Reset settings"
  echo "7) Exit"
  read -p "Your choice (1-7): " main_choice

  case "$main_choice" in
    1)
      ok "Continuing with current settings (FPS=${MAX_FPS:-$DEFAULT_MAX_FPS}, BITRATE=${BITRATE:-$DEFAULT_BITRATE})"
      ;;
    2)
      read -p "FPS (e.g. 60): " v; MAX_FPS=${v:-$DEFAULT_MAX_FPS}
      read -p "Bitrate (e.g. 16M): " b; BITRATE=${b:-$DEFAULT_BITRATE}
      read -p "Turn screen off? (Y/N) [N]: " sc; TURN_SCREEN_OFF=$([[ "$sc" =~ ^[Yy]$ ]] && echo "yes" || echo "no")
      read -p "Disable audio? (Y/N) [N]: " au; NO_AUDIO=$([[ "$au" =~ ^[Yy]$ ]] && echo "yes" || echo "no")
      read -p "Keep screen awake? (Y/N) [Y]: " sa; STAY_AWAKE=$([[ "$sa" =~ ^[Yy]$ ]] && echo "yes" || echo "no")
      read -p "Record session? (Y/N) [N]: " rec; if [[ "$rec" =~ ^[Yy]$ ]]; then RECORD="yes"; read -p "Record file path: " rp; RECORD_PATH=${rp:-$DEFAULT_RECORD_PATH}; else RECORD="no"; fi
      read -p "Save settings? (Y/N): " sv; if [[ "$sv" =~ ^[Yy]$ ]]; then save_config; fi
      ;;
    3)
      echo "1) Paste adb:// link"
      echo "2) Manual IP:PAIR + code"
      read -p "Choice (1/2): " wmode
      if [ "$wmode" = "1" ]; then
        if ! wireless_pair_connect "link"; then warn "Wireless pairing failed"; sleep 1; continue; fi
      else
        if ! wireless_pair_connect "manual"; then warn "Wireless pairing failed"; sleep 1; continue; fi
      fi
      ;;
    4)
      if ! usb_to_wifi_connect; then warn "USB->WiFi failed"; sleep 1; continue; fi
      ;;
    5)
      if ! pick_device_interactive; then warn "Device not selected or error"; sleep 1; continue; fi
      ;;
    6)
      reset_config
      load_config
      sleep 1
      continue
      ;;
    7)
      echo "Exiting..."
      exit 0
      ;;
    *)
      warn "Invalid choice"; sleep 1; continue
      ;;
  esac

  if [ -z "${serial:-}" ]; then
    if ! pick_device_interactive; then
      warn "No device selected."; sleep 1; continue
    fi
  fi

  ARGS=()
  ARGS+=( "--max-fps" "${MAX_FPS:-$DEFAULT_MAX_FPS}" )
  ARGS+=( "--video-bit-rate" "${BITRATE:-$DEFAULT_BITRATE}" )
  [ "${TURN_SCREEN_OFF:-no}" = "yes" ] && ARGS+=( "--turn-screen-off" )
  [ "${STAY_AWAKE:-yes}" = "yes" ] && ARGS+=( "--stay-awake" )
  [ "${NO_AUDIO:-yes}" = "yes" ] && ARGS+=( "--no-audio" )
  [ "${MAXSIZE:-0}" -gt 0 ] 2>/dev/null && ARGS+=( "--max-size" "${MAXSIZE}" ) || true
  [ "${RECORD:-no}" = "yes" ] && ARGS+=( "--record" "${RECORD_PATH}" )

  start_ping_monitor || true
  start_fps_probe || true

  ( while true; do
      clear
      echo -e "${BLUE}scrcpy PRO v2 - Session${NC}"
      echo "Device: ${serial}"
      pingv=$( [ -f "$TMPPING" ] && cat "$TMPPING" || echo "N/A" )
      fpsv=$( [ -f "$TMPFPS" ] && cat "$TMPFPS" || echo "N/A" )
      echo "Ping (ms): $pingv"
      echo "FPS info : $fpsv"
      echo "Args: ${ARGS[*]}"
      echo "Press Ctrl+C to close scrcpy and return here."
      sleep 1
    done ) &

  STATUS_PID=$!

  log "Launching scrcpy: $serial"
  scrcpy -s "$serial" "${ARGS[@]}" || warn "scrcpy ended or failed"

  kill "$STATUS_PID" 2>/dev/null || true
  cleanup
  unset serial
  read -p "Press Enter to return to main menu, or q to quit: " post
  if [[ "$post" =~ ^[Qq]$ ]]; then
    echo "Exiting..."
    exit 0
  fi
done
