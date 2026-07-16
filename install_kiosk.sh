#!/usr/bin/env bash
set -Eeuo pipefail

KIOSK_URL="https://DEINE-WEBSITE.DE"
CHROMIUM_PLATFORM="x11"
OUTPUT_NAME="HDMI-A-1"
OUTPUT_MODE="1920x1080@60Hz"
RESTART_CHROMIUM_EVERY_HOURS=6
DAILY_REBOOT_TIME="04:30"
RUNTIME_WATCHDOG_SEC="15s"

KIOSK_USER="${SUDO_USER:-$USER}"
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
KIOSK_UID="$(id -u "$KIOSK_USER")"
LOG_PREFIX="[kiosk-install]"

log(){ printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die(){ printf '%s FEHLER: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }
trap 'code=$?; printf "%s FEHLER in Zeile %s bei: %s\n" "$LOG_PREFIX" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2; exit "$code"' ERR

[[ $EUID -ne 0 ]] || die "Bitte als normaler Benutzer starten, nicht mit sudo."
[[ -n "$KIOSK_HOME" && -d "$KIOSK_HOME" ]] || die "Home-Verzeichnis nicht gefunden."
[[ "$KIOSK_URL" != "https://DEINE-WEBSITE.DE" ]] || die "Bitte zuerst KIOSK_URL anpassen."
case "$CHROMIUM_PLATFORM" in x11|wayland) ;; *) die "CHROMIUM_PLATFORM muss x11 oder wayland sein." ;; esac

sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

log "System aktualisieren ..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y

log "Pakete installieren ..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  labwc chromium xwayland seatd dbus-user-session wlr-randr \
  fonts-liberation fonts-noto-core fonts-noto-color-emoji curl ca-certificates

if command -v chromium >/dev/null 2>&1; then CHROMIUM_BIN="$(command -v chromium)";
elif command -v chromium-browser >/dev/null 2>&1; then CHROMIUM_BIN="$(command -v chromium-browser)";
else die "Chromium-Binaer wurde nicht gefunden."; fi
LABWC_BIN="$(command -v labwc)"
WLR_RANDR_BIN="$(command -v wlr-randr)"

log "Gruppe seat pruefen ..."
getent group seat >/dev/null 2>&1 || sudo groupadd --system seat
sudo usermod -aG seat,video,input,render "$KIOSK_USER"
sudo systemctl enable --now seatd.service

log "Chromium-Policy setzen ..."
sudo mkdir -p /etc/chromium/policies/managed
sudo tee /etc/chromium/policies/managed/kiosk.json >/dev/null <<'JSON'
{
  "TranslateEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "BrowserSignin": 0,
  "PromotionalTabsEnabled": false
}
JSON
sudo chmod 0644 /etc/chromium/policies/managed/kiosk.json

log "Persistente Logs aktivieren ..."
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald

log "Autologin konfigurieren ..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF2
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
Type=idle
EOF2

install -d -m 0755 "$KIOSK_HOME/kiosk" "$KIOSK_HOME/kiosk/logs" \
  "$KIOSK_HOME/.config/labwc" "$KIOSK_HOME/.config/chromium-kiosk" \
  "$KIOSK_HOME/.config/systemd/user"

cat >"$KIOSK_HOME/.config/labwc/environment" <<'EOF2'
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=labwc
XKB_DEFAULT_LAYOUT=de
EOF2

cat >"$KIOSK_HOME/kiosk/start-kiosk.sh" <<EOF2
#!/usr/bin/env bash
set -u
URL=$(printf '%q' "$KIOSK_URL")
PROFILE="\$HOME/.config/chromium-kiosk"
LOG_DIR="\$HOME/kiosk/logs"
LOG_FILE="\$LOG_DIR/chromium.log"
CHROMIUM_BIN=$(printf '%q' "$CHROMIUM_BIN")
PLATFORM=$(printf '%q' "$CHROMIUM_PLATFORM")
mkdir -p "\$PROFILE" "\$LOG_DIR"
sleep 8
while true; do
  printf '\n===== %s Chromium-Start =====\n' "\$(date --iso-8601=seconds)" >>"\$LOG_FILE"
  EXTRA_FLAGS=()
  [[ "\$PLATFORM" == "wayland" ]] && EXTRA_FLAGS+=(--enable-features=UseOzonePlatform)
  "\$CHROMIUM_BIN" \
    --kiosk \
    "--ozone-platform=\$PLATFORM" \
    "\${EXTRA_FLAGS[@]}" \
    --user-data-dir="\$PROFILE" \
    --no-first-run \
    --no-default-browser-check \
    --noerrdialogs \
    --disable-session-crashed-bubble \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    --autoplay-policy=no-user-gesture-required \
    --disk-cache-size=104857600 \
    --media-cache-size=104857600 \
    "\$URL" >>"\$LOG_FILE" 2>&1
  printf '%s Chromium beendet, Exit-Code %s\n' "\$(date --iso-8601=seconds)" "\$?" >>"\$LOG_FILE"
  sleep 5
done
EOF2
chmod 0755 "$KIOSK_HOME/kiosk/start-kiosk.sh"

cat >"$KIOSK_HOME/kiosk/monitor.sh" <<'EOF2'
#!/usr/bin/env bash
set -u
LOG_DIR="$HOME/kiosk/logs"
LOG_FILE="$LOG_DIR/system.csv"
mkdir -p "$LOG_DIR"
[[ -f "$LOG_FILE" ]] || echo "timestamp,temp_c,throttled,mem_available_kb,swap_used_kb,load1,chromium_rss_kb,disk_root_percent" >"$LOG_FILE"
while true; do
  TIMESTAMP="$(date --iso-8601=seconds)"
  TEMP="$(vcgencmd measure_temp 2>/dev/null | sed -E 's/[^0-9.]//g' || true)"
  THROTTLED="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || true)"
  MEM_AVAILABLE="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  SWAP_TOTAL="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
  SWAP_FREE="$(awk '/SwapFree/ {print $2}' /proc/meminfo)"
  SWAP_USED="$((SWAP_TOTAL - SWAP_FREE))"
  LOAD1="$(awk '{print $1}' /proc/loadavg)"
  CHROMIUM_RSS="$(ps -C chromium -C chromium-browser -o rss= 2>/dev/null | awk '{s += $1} END {print s + 0}')"
  DISK_ROOT="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  echo "$TIMESTAMP,$TEMP,$THROTTLED,$MEM_AVAILABLE,$SWAP_USED,$LOAD1,$CHROMIUM_RSS,$DISK_ROOT" >>"$LOG_FILE"
  LINES="$(wc -l <"$LOG_FILE")"
  if (( LINES > 20000 )); then { head -n 1 "$LOG_FILE"; tail -n 10000 "$LOG_FILE"; } >"${LOG_FILE}.tmp"; mv "${LOG_FILE}.tmp" "$LOG_FILE"; fi
  sleep 60
done
EOF2
chmod 0755 "$KIOSK_HOME/kiosk/monitor.sh"

cat >"$KIOSK_HOME/.config/labwc/autostart" <<EOF2
#!/bin/sh
${WLR_RANDR_BIN} --output ${OUTPUT_NAME} --mode ${OUTPUT_MODE} >>"\$HOME/kiosk/logs/display.log" 2>&1 &
"\$HOME/kiosk/monitor.sh" &
"\$HOME/kiosk/start-kiosk.sh" &
EOF2
chmod 0755 "$KIOSK_HOME/.config/labwc/autostart"

BASH_PROFILE="$KIOSK_HOME/.bash_profile"
sed -i '/^# BEGIN KIOSK LABWC$/,/^# END KIOSK LABWC$/d' "$BASH_PROFILE" 2>/dev/null || true
cat >>"$BASH_PROFILE" <<EOF2

# BEGIN KIOSK LABWC
if [[ -z "\${WAYLAND_DISPLAY:-}" && "\${XDG_VTNR:-0}" == "1" ]]; then
  export XDG_SESSION_TYPE=wayland
  export XDG_CURRENT_DESKTOP=labwc
  export XKB_DEFAULT_LAYOUT=de
  exec dbus-run-session ${LABWC_BIN}
fi
# END KIOSK LABWC
EOF2

CMDLINE_FILE="/boot/firmware/cmdline.txt"
if [[ -f "$CMDLINE_FILE" ]] && ! grep -qw "consoleblank=0" "$CMDLINE_FILE"; then sudo sed -i '1 s/$/ consoleblank=0/' "$CMDLINE_FILE"; fi

sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/20-kiosk-watchdog.conf >/dev/null <<EOF2
[Manager]
RuntimeWatchdogSec=${RUNTIME_WATCHDOG_SEC}
RebootWatchdogSec=5min
EOF2

cat >"$KIOSK_HOME/.config/systemd/user/restart-kiosk.service" <<'EOF2'
[Unit]
Description=Chromium-Kiosk kontrolliert neu starten
[Service]
Type=oneshot
ExecStart=/usr/bin/pkill -TERM -f chromium
SuccessExitStatus=1
EOF2

sudo chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/kiosk" "$KIOSK_HOME/.config/labwc" "$KIOSK_HOME/.config/chromium-kiosk" "$KIOSK_HOME/.config/systemd"
sudo systemctl daemon-reload

[[ -n "$DAILY_REBOOT_TIME" ]] && sudo systemctl enable kiosk-reboot.timer
sudo systemctl enable getty@tty1.service
sudo systemctl daemon-reexec

log "Installation abgeschlossen."
echo "Jetzt neu starten: sudo reboot"
echo "Policy pruefen: cat /etc/chromium/policies/managed/kiosk.json"
echo "Logs: tail -100 ~/kiosk/logs/chromium.log"
