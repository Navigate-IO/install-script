#!/usr/bin/env bash
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

# ─── Configuration ───
BATMAN_DIR="/home/pi/BATMAN-Script"
MCS_TEST_DIR="/home/pi/Recieve-Transfer-MCS-Test"
DRONE_DIR="/home/pi/drone-public"
SX_SDMAH_DIR="/home/pi/sx-sdmah"

echo "========================================="
echo "  Morse Micro Setup Script"
echo "========================================="

# ─── 1. Install system dependencies ───
echo ""
echo "[1/6] Installing system dependencies..."
sudo apt update
sudo apt install -y iperf3 batctl hostapd dnsmasq dhcpcd5 ca-certificates

# Install Liberica JDK 17 (OpenJDK 17 not available for armhf on Bullseye)
if ! java -version 2>&1 | grep -q '"17'; then
    echo "  Installing Liberica JDK 17 (direct .deb)..."
    sudo update-ca-certificates
    sudo wget --no-check-certificate -q https://download.bell-sw.com/java/17.0.17+11/bellsoft-jdk17.0.17+11-linux-arm32-vfp-hflt.deb -O /tmp/bellsoft-jdk17.deb
    sudo apt install -y /tmp/bellsoft-jdk17.deb
    rm -f /tmp/bellsoft-jdk17.deb
else
    echo "  → JDK 17 already installed"
fi

# ─── 2. Clone repositories ───
echo ""
echo "[2/6] Cloning repositories..."

echo "  BATMAN-Script..."
if [ -d "$BATMAN_DIR" ]; then
    echo "    → exists, pulling latest..."
    git -C "$BATMAN_DIR" pull
else
    git clone https://github.com/Navigate-IO/BATMAN-Script.git "$BATMAN_DIR"
fi

echo "  Recieve-Transfer-MCS-Test..."
if [ -d "$MCS_TEST_DIR" ]; then
    echo "    → exists, pulling latest..."
    git -C "$MCS_TEST_DIR" pull
else
    git clone https://github.com/Navigate-IO/Recieve-Transfer-MCS-Test.git "$MCS_TEST_DIR"
fi

echo "  drone-public..."
if [ -d "$DRONE_DIR" ]; then
    echo "    → exists, pulling latest..."
    git -C "$DRONE_DIR" pull
else
    git clone https://github.com/Navigate-IO/drone-public.git "$DRONE_DIR"
fi

# ─── 3. Set up udev rules ───
echo ""
echo "[3/6] Setting up udev rules..."
echo "  Morse (SDIO/mmc1) → wlan0, USB dongle (MediaTek) → wlan1"
sudo tee /etc/udev/rules.d/70-wifi-names.rules > /dev/null <<UDEVEOF
SUBSYSTEM=="net", ACTION=="add", DEVPATH=="*mmc1*", NAME="wlan0"
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="0e8d", NAME="wlan1"
UDEVEOF
sudo udevadm control --reload-rules

# Tear down existing interfaces so udev can rename on reload
echo "  Tearing down interfaces for udev rename..."
sudo ip link set wlan0 down 2>/dev/null || true
sudo ip link set wlan1 down 2>/dev/null || true
sudo rmmod mt76x0u 2>/dev/null || true
sudo rmmod mt76x0_common 2>/dev/null || true
sudo rmmod mt76_usb 2>/dev/null || true
sudo rmmod mt76 2>/dev/null || true
sudo rmmod morse 2>/dev/null || true
sudo rmmod dot11ah 2>/dev/null || true
sleep 2

# Retrigger udev so interfaces come back with correct names
sudo udevadm trigger --action=add --subsystem-match=net
sleep 3

# Reload USB dongle driver (mt76 doesn't auto-reload after rmmod)
echo "  Reloading USB dongle driver..."
sudo modprobe mt76x0u
sleep 5

# ─── 4. Load Morse Micro driver ───
echo ""
echo "========================================="
echo "[4/6] Loading Morse Micro driver"
echo "========================================="

if [ ! -d "$SX_SDMAH_DIR" ]; then
    echo "ERROR: $SX_SDMAH_DIR not found!"
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

echo "  Verifying loaded modules..."
lsmod | grep -E "morse|dot11ah" || echo "WARNING: Modules not showing in lsmod"

# ─── 5. Verify interface naming ───
echo ""
echo "[5/6] Verifying interface naming..."
echo "  wlan0: $(basename "$(readlink -f /sys/class/net/wlan0/device/driver)" 2>/dev/null || echo "not found")"
echo "  wlan1: $(basename "$(readlink -f /sys/class/net/wlan1/device/driver)" 2>/dev/null || echo "not found")"

# ─── 6. Configure RaspAP (AP on wlan1) ───
echo ""
echo "========================================="
echo "[6/6] Configuring RaspAP (wlan1)"
echo "========================================="

sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

sudo mkdir -p /etc/hostapd
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

sudo mkdir -p /etc/dnsmasq.d
sudo tee /etc/dnsmasq.d/wlan1-ap.conf > /dev/null <<EOF
interface=wlan1
dhcp-range=192.168.40.100,192.168.40.200,255.255.0.0,24h
EOF

sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

# Auto-restart override for hostapd
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

# Start AP
sudo ip link set wlan1 up 2>/dev/null || true
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq

echo ""
echo "========================================="
echo "  Install complete!"
echo "========================================="
echo "  hostapd: $(sudo systemctl is-active hostapd)"
echo "  dnsmasq: $(sudo systemctl is-active dnsmasq)"
echo "  watchdog: $(sudo systemctl is-active wlan1-watchdog)"
echo ""
echo "  NOTE: A reboot is recommended to ensure"
echo "  interface naming is fully persistent."
echo "========================================="
