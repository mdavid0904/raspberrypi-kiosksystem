# Raspberry Pi Kiosksystem

Schlankes Web-Kiosksystem für **Raspberry Pi OS Lite 64-Bit** mit:

* labwc / Wayland
* Chromium über XWayland
* automatischem Login
* automatischem Start einer Website
* Full HD mit 60 Hz
* deaktiviertem Übersetzungsdialog
* Hardware-Watchdog
* Monitoring-Logs
* automatischen Sicherheitsupdates

## Voraussetzungen

Empfohlen:

* Raspberry Pi 4 oder 5
* mindestens 2 GB RAM
* Raspberry Pi OS Lite 64-Bit
* stabiles Netzteil
* gute Kühlung
* Ethernet oder stabiles WLAN

## Installation

Repository klonen:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/mdavid0904/raspberrypi-kiosksystem.git
cd raspberrypi-kiosksystem
```

Skript öffnen:

```bash
nano install_kiosk.sh
```

Website eintragen:

```bash
KIOSK_URL="https://DEINE-WEBSITE.DE"
```

Optional anpassen:

```bash
OUTPUT_NAME="HDMI-A-1"
OUTPUT_MODE="1920x1080@60Hz"

ENABLE_UNATTENDED_UPGRADES="true"
UNATTENDED_AUTOMATIC_REBOOT="true"
UNATTENDED_REBOOT_TIME="04:30"
```

Installation starten:

```bash
chmod +x install_kiosk.sh
./install_kiosk.sh
```

Das Skript nicht direkt mit `sudo` starten.

Danach neu starten:

```bash
sudo reboot
```

## Status prüfen

```bash
pgrep -a labwc
pgrep -a Xwayland
pgrep -a chromium
```

Logs:

```bash
tail -100 ~/kiosk/logs/chromium.log
tail -20 ~/kiosk/logs/system.csv
```

Unterspannung und Temperatur:

```bash
vcgencmd get_throttled
vcgencmd measure_temp
```

Optimal:

```text
throttled=0x0
```

Watchdog prüfen:

```bash
systemctl show -p RuntimeWatchdogUSec
```

## Automatische Updates prüfen

```bash
systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager
```

Testlauf:

```bash
sudo unattended-upgrade --dry-run --debug
```

Update-Logs:

```bash
sudo less /var/log/unattended-upgrades/unattended-upgrades.log
```

## Chromium manuell neu starten

```bash
pkill -TERM chromium
```

Das Kiosk-Skript startet Chromium nach einem Absturz automatisch neu.

## HDMI-Ausgang prüfen

Falls kein Bild erscheint:

```bash
wlr-randr
```

Falls nötig, `HDMI-A-1` im Skript oder in folgender Datei ändern:

```bash
nano ~/.config/labwc/autostart
```

## Hinweise

* Full HD ist für Stabilität besser als 4K.
* TeamViewer erst installieren, wenn der reine Kiosk stabil läuft.
* Keine Übertaktung verwenden.
* Für Dauerbetrieb möglichst eine hochwertige SD-Karte oder SSD nutzen.
