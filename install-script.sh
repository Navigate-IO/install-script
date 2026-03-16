#!/usr/bin/env bash
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

# ─── Configuration ───
BATMAN_DIR="/home/pi/BATMAN-Script"
MCS_TEST_DIR="/home/pi/Recieve-Transfer-MCS-Test"
DRONE_DIR="/home/pi/drone-public"
SX_SDMAH_DIR="/home/pi/sx-sdmah"
PHASE_FLAG="/var/tmp/.morse-install-phase1-done"
SCRIPT_PATH="$(realpath "$0")"

# ─── Phase check ───
if [ -f "$PHASE_FLAG" ]; then
    echo "========================================="
    echo "  Morse Micro Setup — Phase 2 (post-reboot)"
    echo "========================================="
    rm -f "$PHASE_FLAG"

    # Remove the one-shot systemd service that re-ran us
    sudo systemctl disable morse-install-phase2.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/morse-install-phase2.service
    sudo systemctl daemon-reload

    # ─── Verify interface naming ───
    echo ""
    echo "[1/3] Verifying interface naming..."
    WLAN0_DRV=$(basename "$(readlink -f /sys/class/net/wlan0/device/driver)" 2>/dev/null || echo "unknown")
    WLAN1_DRV=$(basename "$(readlink -f /sys/class/net/wlan1/device/driver)" 2>/dev/null || echo "unknown")
    echo "  wlan0 driver: $WLAN0_DRV"
    echo "  wlan1 driver: $WLAN1_DRV"

    # ─── Load Morse Micro driver via sx-sdmah ───
    echo ""
    echo "========================================="
    echo "[2/3] Loading Morse Micro driver"
    echo "========================================="

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
    echo "  Verifying loaded modules..."
    lsmod | grep -E "morse|dot11ah" || echo "WARNING: Modules not showing in lsmod"

    # ─── Configure RaspAP base (AP on wlan1) ───
    echo ""
    echo "========================================="
    echo "[3/3] Configuring RaspAP (wlan1)"
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

    echo "RaspAP base configured with auto-restart and wlan1 watchdog."

    echo ""
    echo "========================================="
    echo "  Install script complete!"
    echo "========================================="
    exit 0
fi

# =========================================================
#  PHASE 1 — deps, repos, udev rules, then reboot
# =========================================================
echo "========================================="
echo "  Morse Micro Setup — Phase 1 (pre-reboot)"
echo "========================================="

# ─── 0. Install system dependencies ───
echo ""
echo "[1/4] Installing system dependencies..."
sudo apt update
sudo apt install -y iperf3 batctl hostapd dnsmasq dhcpcd5

# Install Liberica JDK 17 (OpenJDK 17 not available for armhf on Bullseye)
if ! java -version 2>&1 | grep -q '"17'; then
    echo "  Installing Liberica JDK 17 (direct .deb)..."
    sudo apt install -y ca-certificates
    sudo update-ca-certificates
    sudo wget --no-check-certificate -q https://download.bell-sw.com/java/17.0.17+11/bellsoft-jdk17.0.17+11-linux-arm32-vfp-hflt.deb -O /tmp/bellsoft-jdk17.deb
    sudo apt install -y /tmp/bellsoft-jdk17.deb
    rm -f /tmp/bellsoft-jdk17.deb
else
    echo "  → JDK 17 already installed"
fi

# ─── 1. Clone repositories ───
echo ""
echo "[2/4] Cloning repositories..."

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

# ─── 2. Verify sx-sdmah exists ───
echo ""
echo "[3/4] Verifying sx-sdmah..."
if [ ! -d "$SX_SDMAH_DIR" ]; then
    echo "ERROR: $SX_SDMAH_DIR not found!"
    echo "  The sx-sdmah directory must already exist on this Pi."
    exit 1
fi
echo "  → $SX_SDMAH_DIR found."

# ─── 3. Set up udev rules and schedule reboot ───
echo ""
echo "========================================="
echo "[4/4] Setting up udev rules + scheduling reboot"
echo "========================================="
echo "  Morse (SDIO/mmc1) → wlan0, USB dongle (MediaTek) → wlan1"
sudo tee /etc/udev/rules.d/70-wifi-names.rules > /dev/null <<UDEVEOF
SUBSYSTEM=="net", ACTION=="add", DEVPATH=="*mmc1*", NAME="wlan0"
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="0e8d", NAME="wlan1"
UDEVEOF
sudo udevadm control --reload-rules

# Set flag so next run enters phase 2
touch "$PHASE_FLAG"

# Install one-shot systemd service to run phase 2 after reboot
sudo tee /etc/systemd/system/morse-install-phase2.service > /dev/null <<EOF
[Unit]
Description=Morse Micro Install — Phase 2
After=network-online.target multi-user.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable morse-install-phase2.service

echo ""
echo "========================================="
echo "  Phase 1 complete!"
echo "  Rebooting in 5 seconds..."
echo "  Phase 2 will run automatically after reboot."
echo "  Watch progress with: journalctl -u morse-install-phase2 -f"
echo "========================================="
sleep 5
sudo reboot
