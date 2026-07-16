#!/usr/bin/env bash
#
# Raspberry Pi OS Lite 64-bit -> labwc + XWayland + Chromium Kiosk
#
# Enthalten:
# - labwc / Wayland
# - Chromium ueber XWayland
# - Autologin auf tty1
# - Chromium-Kiosk-Autostart
# - Chromium-Policy gegen Uebersetzungsdialog
# - kein seatd und keine Gruppe "seat"
# - kein zeitgesteuerter Chromium-Neustart
# - Full-HD-Ausgabe
# - Hardware-Watchdog
# - Monitoring-Logs
# - automatische Sicherheitsupdates mit unattended-upgrades
# - optionaler Neustart nach Updates
#
# Ausfuehrung:
#   1. Als normaler Benutzer ausfuehren, NICHT mit sudo.
#   2. KIOSK_URL unten anpassen.
#   3. chmod +x install_kiosk.sh
#   4. ./install_kiosk.sh
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# ANPASSEN
# ---------------------------------------------------------------------------

KIOSK_URL="https://DEINE-WEBSITE.DE"

# x11 = Chromium ueber XWayland
# wayland = Chromium nativ unter Wayland
CHROMIUM_PLATFORM="x11"

OUTPUT_NAME="HDMI-A-1"
OUTPUT_MODE="1920x1080@60Hz"

RUNTIME_WATCHDOG_SEC="15s"

# Automatische Sicherheitsupdates
ENABLE_UNATTENDED_UPGRADES="true"

# Automatischer Neustart, wenn ein Update ihn erfordert.
# "true" oder "false"
UNATTENDED_AUTOMATIC_REBOOT="true"
UNATTENDED_REBOOT_TIME="04:30"

# ---------------------------------------------------------------------------
# INTERN
# ---------------------------------------------------------------------------

KIOSK_USER="${SUDO_USER:-$USER}"
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
LOG_PREFIX="[kiosk-install]"

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

die() {
    printf '%s FEHLER: %s\n' "$LOG_PREFIX" "$*" >&2
    exit 1
}

on_error() {
    local code=$?
    printf '%s FEHLER in Zeile %s bei: %s\n' \
        "$LOG_PREFIX" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2
    exit "$code"
}
trap on_error ERR

if [[ $EUID -eq 0 ]]; then
    die "Bitte als normaler Benutzer starten, nicht mit sudo."
fi

[[ -n "$KIOSK_HOME" && -d "$KIOSK_HOME" ]] \
    || die "Home-Verzeichnis fuer $KIOSK_USER wurde nicht gefunden."

[[ "$KIOSK_URL" != "https://DEINE-WEBSITE.DE" ]] \
    || die "Bitte zuerst KIOSK_URL oben im Skript anpassen."

case "$CHROMIUM_PLATFORM" in
    x11|wayland) ;;
    *) die "CHROMIUM_PLATFORM muss x11 oder wayland sein." ;;
esac

case "$ENABLE_UNATTENDED_UPGRADES" in
    true|false) ;;
    *) die "ENABLE_UNATTENDED_UPGRADES muss true oder false sein." ;;
esac

case "$UNATTENDED_AUTOMATIC_REBOOT" in
    true|false) ;;
    *) die "UNATTENDED_AUTOMATIC_REBOOT muss true oder false sein." ;;
esac

[[ "$UNATTENDED_REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || die "UNATTENDED_REBOOT_TIME muss HH:MM sein."

sudo -v

while true; do
    sudo -n true
    sleep 50
    kill -0 "$$" 2>/dev/null || exit
done &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

log "System aktualisieren ..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y

log "Pakete installieren ..."
PACKAGES=(
    labwc
    chromium
    xwayland
    dbus-user-session
    wlr-randr
    unclutter-xfixes
    fonts-liberation
    fonts-noto-core
    fonts-noto-color-emoji
    curl
    ca-certificates
)

if [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]]; then
    PACKAGES+=(unattended-upgrades apt-listchanges)
fi

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

if command -v chromium >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v chromium)"
elif command -v chromium-browser >/dev/null 2>&1; then
    CHROMIUM_BIN="$(command -v chromium-browser)"
else
    die "Chromium-Binaer wurde nicht gefunden."
fi

LABWC_BIN="$(command -v labwc)"
WLR_RANDR_BIN="$(command -v wlr-randr)"

log "Benutzer zu Grafik- und Eingabegruppen hinzufuegen ..."
sudo usermod -aG video,input,render "$KIOSK_USER"

if [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]]; then
    log "Automatische Sicherheitsupdates konfigurieren ..."

    sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    sudo tee /etc/apt/apt.conf.d/52kiosk-unattended-upgrades >/dev/null <<EOF
Unattended-Upgrade::Automatic-Reboot "${UNATTENDED_AUTOMATIC_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${UNATTENDED_REBOOT_TIME}";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::SyslogEnable "true";
EOF

    sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
fi

log "Chromium-Policy setzen ..."
sudo mkdir -p /etc/chromium/policies/managed
sudo tee /etc/chromium/policies/managed/kiosk.json >/dev/null <<'EOF'
{
  "TranslateEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "BrowserSignin": 0,
  "PromotionalTabsEnabled": false
}
EOF
sudo chmod 0644 /etc/chromium/policies/managed/kiosk.json

log "Persistente Systemprotokolle aktivieren ..."
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald

log "Autologin auf tty1 konfigurieren ..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${KIOSK_USER} --noclear %I \$TERM
Type=idle
EOF

log "Verzeichnisse erstellen ..."
install -d -m 0755 \
    "$KIOSK_HOME/kiosk" \
    "$KIOSK_HOME/kiosk/logs" \
    "$KIOSK_HOME/.config/labwc" \
    "$KIOSK_HOME/.config/chromium-kiosk"

log "labwc-Umgebung schreiben ..."
cat >"$KIOSK_HOME/.config/labwc/environment" <<'EOF'
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=labwc
XKB_DEFAULT_LAYOUT=de
EOF

log "Chromium-Kiosk-Skript schreiben ..."
cat >"$KIOSK_HOME/kiosk/start-kiosk.sh" <<EOF
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
    printf '\n===== %s Chromium-Start =====\n' \
        "\$(date --iso-8601=seconds)" >>"\$LOG_FILE"

    EXTRA_FLAGS=()
    if [[ "\$PLATFORM" == "wayland" ]]; then
        EXTRA_FLAGS+=(--enable-features=UseOzonePlatform)
    fi

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

    EXIT_CODE=\$?
    printf '%s Chromium beendet, Exit-Code %s\n' \
        "\$(date --iso-8601=seconds)" "\$EXIT_CODE" >>"\$LOG_FILE"

    # Nur nach echtem Beenden oder Absturz neu starten.
    sleep 5
done
EOF
chmod 0755 "$KIOSK_HOME/kiosk/start-kiosk.sh"

log "Monitoring-Skript schreiben ..."
cat >"$KIOSK_HOME/kiosk/monitor.sh" <<'EOF'
#!/usr/bin/env bash
set -u

LOG_DIR="$HOME/kiosk/logs"
LOG_FILE="$LOG_DIR/system.csv"
mkdir -p "$LOG_DIR"

if [[ ! -f "$LOG_FILE" ]]; then
    echo "timestamp,temp_c,throttled,mem_available_kb,swap_used_kb,load1,chromium_rss_kb,disk_root_percent" >"$LOG_FILE"
fi

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

    echo "$TIMESTAMP,$TEMP,$THROTTLED,$MEM_AVAILABLE,$SWAP_USED,$LOAD1,$CHROMIUM_RSS,$DISK_ROOT" \
        >>"$LOG_FILE"

    LINES="$(wc -l <"$LOG_FILE")"
    if (( LINES > 20000 )); then
        {
            head -n 1 "$LOG_FILE"
            tail -n 10000 "$LOG_FILE"
        } >"${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi

    sleep 60
done
EOF
chmod 0755 "$KIOSK_HOME/kiosk/monitor.sh"

log "labwc-Autostart schreiben ..."
cat >"$KIOSK_HOME/.config/labwc/autostart" <<EOF
#!/bin/sh

${WLR_RANDR_BIN} \
    --output ${OUTPUT_NAME} \
    --mode ${OUTPUT_MODE} \
    >>"\$HOME/kiosk/logs/display.log" 2>&1 &

"\$HOME/kiosk/monitor.sh" &
"\$HOME/kiosk/start-kiosk.sh" &

# Mauszeiger unter XWayland nach 0,5 Sekunden Inaktivitaet ausblenden.
# Die Display-Nummer wird automatisch aus dem XWayland-Socket ermittelt.
/bin/sh -c '
sleep 12
for socket in /tmp/.X11-unix/X*; do
    [ -S "\$socket" ] || continue
    number="\${socket##*/X}"
    DISPLAY=":\$number" /usr/bin/unclutter -idle 0.5 -root &
    break
done
' >>"\$HOME/kiosk/logs/unclutter.log" 2>&1 &
EOF
chmod 0755 "$KIOSK_HOME/.config/labwc/autostart"

log "labwc beim lokalen Login starten ..."
BASH_PROFILE="$KIOSK_HOME/.bash_profile"
touch "$BASH_PROFILE"
sed -i '/^# BEGIN KIOSK LABWC$/,/^# END KIOSK LABWC$/d' "$BASH_PROFILE"

cat >>"$BASH_PROFILE" <<EOF

# BEGIN KIOSK LABWC
if [[ -z "\${WAYLAND_DISPLAY:-}" && "\${XDG_VTNR:-0}" == "1" ]]; then
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=labwc
    export XKB_DEFAULT_LAYOUT=de
    exec dbus-run-session ${LABWC_BIN}
fi
# END KIOSK LABWC
EOF

log "Konsolen-Blanking deaktivieren ..."
CMDLINE_FILE="/boot/firmware/cmdline.txt"
if [[ -f "$CMDLINE_FILE" ]] && ! grep -qw "consoleblank=0" "$CMDLINE_FILE"; then
    sudo sed -i '1 s/$/ consoleblank=0/' "$CMDLINE_FILE"
fi

log "Hardware-Watchdog konfigurieren ..."
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/20-kiosk-watchdog.conf >/dev/null <<EOF
[Manager]
RuntimeWatchdogSec=${RUNTIME_WATCHDOG_SEC}
RebootWatchdogSec=5min
EOF

log "Dateibesitz korrigieren ..."
sudo chown -R "$KIOSK_USER:$KIOSK_USER" \
    "$KIOSK_HOME/kiosk" \
    "$KIOSK_HOME/.config/labwc" \
    "$KIOSK_HOME/.config/chromium-kiosk" \
    "$KIOSK_HOME/.bash_profile"

log "systemd neu laden ..."
sudo systemctl daemon-reload
sudo systemctl enable getty@tty1.service
sudo systemctl daemon-reexec

echo
log "Installation abgeschlossen."
echo
echo "Jetzt neu starten:"
echo "  sudo reboot"
echo
echo "Automatische Updates pruefen:"
echo "  systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager"
echo "  sudo unattended-upgrade --dry-run --debug"
echo "  cat /etc/apt/apt.conf.d/20auto-upgrades"
echo "  cat /etc/apt/apt.conf.d/52kiosk-unattended-upgrades"
echo
echo "Kiosk pruefen:"
echo "  pgrep -a labwc"
echo "  pgrep -a Xwayland"
echo "  pgrep -a chromium"
echo "  tail -100 ~/kiosk/logs/chromium.log"
echo "  tail -20 ~/kiosk/logs/system.csv"
echo "  vcgencmd get_throttled"
echo "  systemctl show -p RuntimeWatchdogUSec"
