#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───
BATMAN_DIR="/home/pi/BATMAN-Script"
MCS_TEST_DIR="/home/pi/Recieve-Transfer-MCS-Test"
DRONE_DIR="/home/pi/drone-public"
FIRMWARE_DIR="/home/pi/morse-firmware"
SX_SDMAH_DIR="/home/pi/sx-sdmah"

echo "========================================="
echo "  Morse Micro Setup Script"
echo "========================================="

# ─── 0. Install system dependencies ───
echo ""
echo "[0/6] Installing system dependencies..."
sudo apt update
sudo apt install -y iperf3 batctl hostapd dnsmasq dhcpcd5

# Install Liberica JDK 17 (OpenJDK 17 not available for armhf on Bullseye)
if ! java -version 2>&1 | grep -q '"17'; then
    echo "  Installing Liberica JDK 17..."
    wget -q -O - https://download.bell-sw.com/pki/GPG-KEY-bellsoft | sudo apt-key add -
    echo "deb https://apt.bell-sw.com/ stable main" | sudo tee /etc/apt/sources.list.d/bellsoft.list
    sudo apt update
    sudo apt install -y bellsoft-java17
else
    echo "  → JDK 17 already installed"
fi

# ─── 1. Clone repositories ───
echo ""
echo "[1/6] Cloning BATMAN-Script..."
if [ -d "$BATMAN_DIR" ]; then
    echo "  → $BATMAN_DIR already exists, pulling latest..."
    git -C "$BATMAN_DIR" pull
else
    git clone https://github.com/Navigate-IO/BATMAN-Script.git "$BATMAN_DIR"
fi

echo "[2/6] Cloning Recieve-Transfer-MCS-Test..."
if [ -d "$MCS_TEST_DIR" ]; then
    echo "  → $MCS_TEST_DIR already exists, pulling latest..."
    git -C "$MCS_TEST_DIR" pull
else
    git clone https://github.com/Navigate-IO/Recieve-Transfer-MCS-Test.git "$MCS_TEST_DIR"
fi

echo "[3/6] Cloning drone-public..."
if [ -d "$DRONE_DIR" ]; then
    echo "  → $DRONE_DIR already exists, pulling latest..."
    git -C "$DRONE_DIR" pull
else
    git clone https://github.com/Navigate-IO/drone-public.git "$DRONE_DIR"
fi

echo "[4/6] Cloning morse-firmware..."
if [ -d "$FIRMWARE_DIR" ]; then
    echo "  → $FIRMWARE_DIR already exists, pulling latest..."
    git -C "$FIRMWARE_DIR" pull
else
    git clone https://github.com/Navigate-IO/morse-firmware.git "$FIRMWARE_DIR"
fi

# Install firmware to /lib/firmware/morse
echo "  Installing firmware to /lib/firmware/morse..."
sudo mkdir -p /lib/firmware/morse
sudo cp "$FIRMWARE_DIR"/*.bin /lib/firmware/morse/

# Install device tree overlays for SX-SDMAH HAT
echo "  Installing device tree overlays..."
sudo cp "$FIRMWARE_DIR"/mm_wlan.dtbo "$FIRMWARE_DIR"/morse-ps.dtbo "$FIRMWARE_DIR"/sdio.dtbo /boot/overlays/ 2>/dev/null || true
sudo cp "$FIRMWARE_DIR"/mm_wlan.dtbo "$FIRMWARE_DIR"/morse-ps.dtbo "$FIRMWARE_DIR"/sdio.dtbo /boot/firmware/overlays/ 2>/dev/null || true

# Add overlay config to /boot/firmware/config.txt if not already present
if ! grep -q "mm_wlan" /boot/firmware/config.txt 2>/dev/null; then
    echo "  Adding Morse Micro overlays to /boot/firmware/config.txt..."
    sudo tee -a /boot/firmware/config.txt > /dev/null <<DTEOF

# Morse Micro SX-SDMAH HAT
dtoverlay=sdio
dtoverlay=mm_wlan
dtoverlay=morse-ps
gpio=16=ip,pu
DTEOF
else
    echo "  → Morse overlays already in /boot/firmware/config.txt"
fi

# Blacklist Broadcom WiFi so it doesn't interfere
if [ ! -f /etc/modprobe.d/blacklist-brcm.conf ]; then
    echo "  Blacklisting brcmfmac..."
    echo "blacklist brcmfmac" | sudo tee /etc/modprobe.d/blacklist-brcm.conf > /dev/null
else
    echo "  → brcmfmac already blacklisted"
fi

# ─── 2. Load Morse Micro driver via sx-sdmah ───
echo ""
echo "========================================="
echo "[5/6] Loading Morse Micro driver"
echo "========================================="

if [ ! -d "$SX_SDMAH_DIR" ]; then
    echo "ERROR: $SX_SDMAH_DIR not found!"
    echo "  The sx-sdmah directory must already exist on this Pi."
    exit 1
fi

if [ ! -f "$SX_SDMAH_DIR/load_driver.sh" ]; then
    echo "ERROR: $SX_SDMAH_DIR/load_driver.sh not found!"
    exit 1
fi

echo "Running load_driver.sh..."
cd "$SX_SDMAH_DIR"
sudo bash load_driver.sh

echo "Waiting 20s for driver to stabilize..."
sleep 20

echo ""
echo "========================================="
echo "  Verifying loaded modules..."
echo "========================================="
lsmod | grep -E "morse|dot11ah" || echo "WARNING: Modules not showing in lsmod"

# ─── 3. Configure RaspAP base (AP on wlan1) ───
echo ""
echo "========================================="
echo "[6/6] Configuring RaspAP (wlan1)"
echo "========================================="

sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=wlan1
driver=nl80211
ssid=uas6
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=hello123
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

sudo sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd 2>/dev/null || true

sudo tee /etc/dnsmasq.d/wlan1-ap.conf > /dev/null <<EOF
interface=wlan1
dhcp-range=192.168.40.100,192.168.40.200,255.255.0.0,24h
EOF

sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

# Add auto-restart override for hostapd (survives USB dongle resets)
sudo mkdir -p /etc/systemd/system/hostapd.service.d
sudo tee /etc/systemd/system/hostapd.service.d/restart.conf > /dev/null <<EOF
[Service]
Restart=on-failure
RestartSec=3
EOF

# Watchdog service: monitors wlan1 and recovers from unplug/replug
sudo mkdir -p /opt/mcs-test
sudo tee /opt/mcs-test/wlan1-watchdog.sh > /dev/null <<'WATCHDOG'
#!/bin/bash
LAST_STATE="unknown"

while true; do
    if ip link show wlan1 &>/dev/null; then
        # Interface exists
        if ! ip link show wlan1 | grep -q "state UP"; then
            ip link set wlan1 up 2>/dev/null
            sleep 2
            systemctl restart hostapd 2>/dev/null
            systemctl restart dnsmasq 2>/dev/null
            echo "[watchdog] wlan1 was down, brought up and restarted hostapd/dnsmasq"
            LAST_STATE="recovered"
        elif [ "$LAST_STATE" = "missing" ]; then
            ip link set wlan1 up 2>/dev/null
            sleep 2
            systemctl restart hostapd 2>/dev/null
            systemctl restart dnsmasq 2>/dev/null
            echo "[watchdog] wlan1 reappeared after unplug, restarted hostapd/dnsmasq"
            LAST_STATE="recovered"
        else
            LAST_STATE="up"
        fi
    else
        if [ "$LAST_STATE" != "missing" ]; then
            echo "[watchdog] wlan1 disappeared (dongle unplugged?), waiting for replug..."
        fi
        LAST_STATE="missing"
    fi
    sleep 3
done
WATCHDOG
sudo chmod +x /opt/mcs-test/wlan1-watchdog.sh

sudo tee /etc/systemd/system/wlan1-watchdog.service > /dev/null <<EOF
[Unit]
Description=wlan1 AP watchdog
After=network-online.target hostapd.service

[Service]
Type=simple
ExecStart=/opt/mcs-test/wlan1-watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable wlan1-watchdog.service
sudo systemctl start wlan1-watchdog.service

echo "RaspAP base configured with auto-restart and wlan1 watchdog."

echo ""
echo "========================================="
echo "  Install script complete!"
echo "========================================="
