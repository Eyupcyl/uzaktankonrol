#!/usr/bin/env bash
# scrcpy_pro_v2_fixed.sh
# Düzeltilmiş: USB->WiFi, QR/link parsing, config save/load, status panel, cleanup
# Gereksinimler: adb, scrcpy, qrencode (opsiyonel), ping (iputils)

set -o errexit
set -o pipefail
set -o nounset

CONF="$HOME/.scrcpy_pro_v2.conf"
LOG="$HOME/.scrcpy_pro_v2.log"
TMPPING="/tmp/scrcpy_v2_ping.$$"
TMPFPS="/tmp/scrcpy_v2_fps.$$"
PING_INTERVAL=2

# Defaults
DEFAULT_MAX_FPS=60
DEFAULT_BITRATE="16M"
DEFAULT_MAXSIZE=0
DEFAULT_TURN_SCREEN_OFF="no"
DEFAULT_STAY_AWAKE="yes"
DEFAULT_NO_AUDIO="yes"
DEFAULT_RECORD="no"
DEFAULT_RECORD_PATH="$HOME/scrcpy_record_$(date +%Y%m%d_%H%M%S).mp4"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log(){ echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
ok(){ echo -e "${GREEN}$*${NC}"; }
warn(){ echo -e "${YELLOW}$*${NC}"; }
err(){ echo -e "${RED}$*${NC}"; }

# dependency check
check_deps(){
  local miss=0
  for cmd in adb scrcpy; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Gerekli komut bulunamadı: $cmd"
      miss=1
    fi
  done
  if ! command -v ping >/dev/null 2>&1; then
    warn "ping komutu bulunamadı; ping gösterilmeyecek"
  fi
  if [ $miss -eq 1 ]; then
    err "Gereksinimleri kurup tekrar deneyin."
    return 1
  fi
  return 0
}

# load/save config
load_config(){
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    source "$CONF"
    ok "Ayarlar yüklendi: $CONF"
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
  ok "Ayarlar kaydedildi: $CONF"
}

reset_config(){
  rm -f "$CONF"
  ok "Ayar dosyası silindi."
}

# device helpers
get_connected_devices(){
  # returns lines of serials (only those with 'device' state)
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
    echo "Bağlı cihazlar:"
    for i in "${!arr[@]}"; do
      echo "$((i+1))) ${arr[$i]}"
    done
    read -p "Seçim numarası: " sel
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
  # choose usb devices (serials without colon)
  mapfile -t usbs < <(adb devices | awk 'NR>1 && $2=="device" && $1 !~ /:/ {print $1}')
  if [ ${#usbs[@]} -eq 0 ]; then
    err "USB ile bağlı cihaz bulunamadı."
    return 1
  fi
  if [ ${#usbs[@]} -gt 1 ]; then
    echo "USB bağlı cihazlar:"
    for i in "${!usbs[@]}"; do echo "$((i+1))) ${usbs[$i]}"; done
    read -p "Hangi cihaz (numara): " n
    dev=${usbs[$((n-1))]}
  else
    dev=${usbs[0]}
  fi
  ok "Seçilen USB cihaz: $dev"
  adb -s "$dev" tcpip 5555 >/dev/null 2>&1 || { err "adb tcpip başarısız"; return 2; }
  sleep 1
  # try to query wlan0 ip via adb shell (may require different interface)
  IP=$(adb -s "$dev" shell ip -f inet addr show wlan0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 || true)
  if [ -z "$IP" ]; then
    warn "Cihaz IP alınamadı. Manuel girmeniz istenecek."
    read -p "Telefon IP adresini girin (örn 192.168.1.56): " IP
  fi
  TARGET="${IP}:5555"
  ok "adb connect $TARGET"
  adb connect "$TARGET" >/dev/null 2>&1 || { err "adb connect başarısız"; return 3; }
  serial="$TARGET"
  sleep 1
  return 0
}

# parse adb:// link or manual pair
wireless_pair_connect(){
  # mode: "link" or "manual"
  local mode="$1"
  if [ "$mode" = "link" ]; then
    read -p "Lütfen adb:// linkini yapıştırın: " QRLINK
    IPPAIR=$(echo "$QRLINK" | sed -n 's|adb://\([^?]*\)\?.*|\1|p' || true)
    PAIRCODE=$(echo "$QRLINK" | sed -n 's/.*pairing_code=\([0-9]*\).*/\1/p' || true)
    if [ -z "$IPPAIR" ] || [ -z "$PAIRCODE" ]; then
      err "Link çözümlenemedi."
      return 2
    fi
  else
    read -p "IP ve Pair port girin (örn 192.168.1.56:42345): " IPPAIR
    read -p "Telefon ekranındaki 6 haneli pairing kodunu girin: " PAIRCODE
  fi
  read -p "Connect port (default 5555): " CONPORT
  CONPORT=${CONPORT:-5555}
  iponly=$(echo "$IPPAIR" | cut -d: -f1)
  # ping test (optional)
  if command -v ping >/dev/null 2>&1; then
    if ! ping -c1 -W1 "$iponly" >/dev/null 2>&1; then
      warn "Cihaza ping atılamıyor: $iponly (devam edeceğim ama bağlantı başarısız olabilir)"
    fi
  fi
  # pair
  echo "$PAIRCODE" | adb pair "$IPPAIR" >/dev/null 2>&1 || { err "adb pair başarısız"; return 3; }
  adb connect "${iponly}:${CONPORT}" >/dev/null 2>&1 || { err "adb connect başarısız"; return 4; }
  serial="${iponly}:${CONPORT}"
  ok "Kablosuz bağlı: $serial"
  return 0
}

# ping monitor
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

# fps probe (best-effort)
start_fps_probe(){
  ( while true; do
      # crude: try to get focused package and dumpsys gfxinfo (may require permissions)
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

# show device info (model/brand/android)
show_device_info(){
  local s="$1"
  # handle case where s may contain colon port
  local dev="$s"
  ok "Cihaz bilgileri alınıyor..."
  model=$(adb -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "N/A")
  brand=$(adb -s "$dev" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r' || echo "N/A")
  android_v=$(adb -s "$dev" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "N/A")
  echo "────────────────────────────────────────"
  echo -e "Model    : ${brand} ${model}"
  echo -e "Android  : ${android_v}"
  echo -e "Serial   : ${dev}"
  echo "────────────────────────────────────────"
}

# main
if ! check_deps; then
  exit 1
fi

load_config

while true; do
  clear
  echo -e "${BLUE}📱 scrcpy PRO v2 - QR+INFO (fix)${NC}"
  echo "1) Mevcut ayarlarla başlat"
  echo "2) Yeni ayar oluştur (kaydetilebilir)"
  echo "3) Kablosuz (QR/link veya manuel)"
  echo "4) USB -> WiFi (otomatik)"
  echo "5) Mevcut cihaz listesinden seç"
  echo "6) Ayarları sıfırla"
  echo "7) Çıkış"
  read -p "Seçiminiz (1-7): " main_choice

  case "$main_choice" in
    1)
      # use loaded config, then ask connection type
      ok "Mevcut ayarlarla devam ediliyor (FPS=${MAX_FPS:-$DEFAULT_MAX_FPS}, BITRATE=${BITRATE:-$DEFAULT_BITRATE})"
      ;;
    2)
      read -p "FPS (ör: 60): " v; MAX_FPS=${v:-$DEFAULT_MAX_FPS}
      read -p "Bitrate (ör: 16M): " b; BITRATE=${b:-$DEFAULT_BITRATE}
      read -p "Ekranı kapat (E/H) [H]: " sc; TURN_SCREEN_OFF=$([[ "$sc" =~ ^[Ee]$ ]] && echo "yes" || echo "no")
      read -p "Ses kapalı olsun mu? (E/H) [H]: " au; NO_AUDIO=$([[ "$au" =~ ^[Ee]$ ]] && echo "yes" || echo "no")
      read -p "Ekran uyanık kalsın mı? (E/H) [E]: " sa; STAY_AWAKE=$([[ "$sa" =~ ^[Ee]$ ]] && echo "yes" || echo "no")
      read -p "Kayıt al (E/H) [H]: " rec; if [[ "$rec" =~ ^[Ee]$ ]]; then RECORD="yes"; read -p "Kayıt dosyası yolu: " rp; RECORD_PATH=${rp:-$DEFAULT_RECORD_PATH}; else RECORD="no"; fi
      read -p "Ayarları kaydetmek istiyor musunuz? (E/H): " sv; if [[ "$sv" =~ ^[Ee]$ ]]; then save_config; fi
      ;;
    3)
      echo "1) adb:// linki yapıştır (telefondan alınan link)"
      echo "2) Manuel IP:PAIR + kod"
      read -p "Seçiminiz (1/2): " wmode
      if [ "$wmode" = "1" ]; then
        if ! wireless_pair_connect "link"; then warn "Kablosuz pairing başarısız"; sleep 1; continue; fi
      else
        if ! wireless_pair_connect "manual"; then warn "Kablosuz pairing başarısız"; sleep 1; continue; fi
      fi
      ;;
    4)
      if ! usb_to_wifi_connect; then warn "USB->WiFi başarısız"; sleep 1; continue; fi
      ;;
    5)
      if ! pick_device_interactive; then warn "Cihaz seçilmedi veya hata"; sleep 1; continue; fi
      ;;
    6)
      reset_config
      load_config
      sleep 1
      continue
      ;;
    7)
      echo "Çıkılıyor..."
      exit 0
      ;;
    *)
      warn "Geçersiz seçim"; sleep 1; continue
      ;;
  esac

  # ensure serial is set (pick device if needed)
  if [ -z "${serial:-}" ]; then
    if ! pick_device_interactive; then
      warn "Cihaz yok veya seçilmedi."; sleep 1; continue
    fi
  fi

  # prepare scrcpy args
  ARGS=()
  ARGS+=( "--max-fps" "${MAX_FPS:-$DEFAULT_MAX_FPS}" )
  ARGS+=( "--video-bit-rate" "${BITRATE:-$DEFAULT_BITRATE}" )
  [ "${TURN_SCREEN_OFF:-no}" = "yes" ] && ARGS+=( "--turn-screen-off" )
  [ "${STAY_AWAKE:-yes}" = "yes" ] && ARGS+=( "--stay-awake" )
  [ "${NO_AUDIO:-yes}" = "yes" ] && ARGS+=( "--no-audio" )
  [ "${MAXSIZE:-0}" -gt 0 ] 2>/dev/null && ARGS+=( "--max-size" "${MAXSIZE}" ) || true
  [ "${RECORD:-no}" = "yes" ] && ARGS+=( "--record" "${RECORD_PATH}" )

  # start monitors
  start_ping_monitor || true
  start_fps_probe || true

  # background status display
  ( while true; do
      clear
      echo -e "${BLUE}scrcpy PRO v2 - session${NC}"
      echo "Device: ${serial}"
      pingv=$( [ -f "$TMPPING" ] && cat "$TMPPING" || echo "N/A" )
      fpsv=$( [ -f "$TMPFPS" ] && cat "$TMPFPS" || echo "N/A" )
      echo "Ping (ms): $pingv"
      echo "FPS info : $fpsv"
      echo "Args: ${ARGS[*]}"
      echo "Ctrl+C ile scrcpy kapatılacak ve buraya geri dönülecek."
      sleep 1
    done ) &

  STATUS_PID=$!

  log "scrcpy başlatılıyor: $serial"
  # start scrcpy (this blocks until scrcpy exits)
  scrcpy -s "$serial" "${ARGS[@]}" || warn "scrcpy sonlandı veya hata oluştu"

  # scrcpy kapandığında, temizle
  kill "$STATUS_PID" 2>/dev/null || true
  cleanup
  unset serial
  read -p "Ana menüye dönmek için Enter, çıkmak için q yazıp Enter: " post
  if [[ "$post" =~ ^[Qq]$ ]]; then
    echo "Çıkılıyor..."
    exit 0
  fi
done
