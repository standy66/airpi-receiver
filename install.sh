#!/bin/bash
# Set up AirPi on a fresh Raspberry Pi OS Lite (64-bit, Trixie).
# Run on the Pi as a user with sudo, from a checkout of this repository:
#     ./install.sh
# Then reboot. Safe to run again (each step checks before changing anything).
#
# Settings (environment variables):
#   DAC_CARD        ALSA card name of the USB DAC, see `aplay -l`   (default: QX11)
#   HDMI_MODE       HDMI output for the now-playing screen          (default: 3840x2160-32@30)
#   SHAIRPORT_REF   shairport-sync commit/tag to build              (default: cf6998da, i.e. 5.6+7)
#   TV_MAC          TV's MAC address, to wake TVs that ignore HDMI-CEC in standby (default: none)
set -euo pipefail

DAC_CARD=${DAC_CARD:-QX11}
HDMI_MODE=${HDMI_MODE:-3840x2160-32@30}
SHAIRPORT_REF=${SHAIRPORT_REF:-cf6998da}
TV_MAC=${TV_MAC:-}
REPO=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive

echo "== packages"
sudo apt-get update -q
sudo apt-get install -y -q --no-install-recommends \
  build-essential git autoconf automake libtool pkg-config systemd-dev \
  libpopt-dev libconfig-dev libasound2-dev avahi-daemon libavahi-client-dev libssl-dev \
  libsoxr-dev libplist-dev libplist-utils libsodium-dev libavutil-dev libavcodec-dev \
  libavformat-dev libswresample-dev uuid-dev libgcrypt-dev xxd \
  alsa-utils v4l-utils libdrm-tests python3-pil fonts-dejavu-core

echo "== shairport-sync ($SHAIRPORT_REF)"
mkdir -p ~/src
[ -d ~/src/shairport-sync ] || git clone -q https://github.com/mikebrady/shairport-sync.git ~/src/shairport-sync
cd ~/src/shairport-sync
git fetch -q && git checkout -q "$SHAIRPORT_REF"
autoreconf -fi >/dev/null
# AirPlay 2 support is compiled in but not used (service_type = "classic"); see README.
./configure --sysconfdir=/etc --with-alsa --with-soxr --with-avahi --with-ssl=openssl \
  --with-systemd-startup --with-airplay-2 --with-ffmpeg --with-metadata --with-metadata-pipe >/dev/null
make -j4 >/dev/null
sudo make install >/dev/null
shairport-sync -V

echo "== configuration"
[ -f /etc/shairport-sync.conf ] && sudo cp -n /etc/shairport-sync.conf /etc/shairport-sync.conf.original
sed "s/QX11/$DAC_CARD/g" "$REPO/config/shairport-sync.conf" | sudo tee /etc/shairport-sync.conf >/dev/null

# Onboard and HDMI audio off: the USB DAC becomes the only sound card.
CFG=/boot/firmware/config.txt
sudo cp -n $CFG $CFG.bak
sudo sed -i 's/^dtparam=audio=on/dtparam=audio=off/; s/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,noaudio/' $CFG

# Fixed HDMI mode in 32-bit colour, no console blanking or cursor over the cover.
CMD=/boot/firmware/cmdline.txt
sudo cp -n $CMD $CMD.bak
sudo sed -i -E 's/ ?video=HDMI-A-1:[^ ]*//; s/ ?consoleblank=[^ ]*//; s/ ?vt.global_cursor_default=[^ ]*//' $CMD
sudo sed -i "1 s|\$| video=HDMI-A-1:$HDMI_MODE consoleblank=0 vt.global_cursor_default=0|" $CMD

# Wi-Fi power saving causes audio dropouts.
WIFI=$(nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2 ~ /wireless/ {print $1; exit}')
[ -n "$WIFI" ] && sudo nmcli connection modify "$WIFI" 802-11-wireless.powersave 2

echo "== now-playing screen and HDMI-CEC"
sed "s/QX11/$DAC_CARD/g" "$REPO/bin/airpi-display" | sudo tee /usr/local/bin/airpi-display >/dev/null
sudo chmod 755 /usr/local/bin/airpi-display
sudo install -m 644 "$REPO/systemd/airpi-display.service" "$REPO/systemd/airpi-cec.service" /etc/systemd/system/
sudo sed -i "s/^User=pi$/User=$USER/; s/^Environment=AIRPI_TV_MAC=.*/Environment=AIRPI_TV_MAC=$TV_MAC/" \
  /etc/systemd/system/airpi-display.service

sudo systemctl daemon-reload
sudo systemctl enable shairport-sync airpi-cec airpi-display

echo "== done: reboot to apply the boot settings (sudo reboot)"
