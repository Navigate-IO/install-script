#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───
DRIVER_DIR="/home/pi/morse_driver"
BATMAN_DIR="/home/pi/BATMAN-Script"
MCS_TEST_DIR="/home/pi/Recieve-Transfer-MCS-Test"

echo "========================================="
echo "  Morse Micro Setup Script"
echo "========================================="

# ─── 1. Clone repositories ───
echo ""
echo "[1/3] Cloning morse-micro-64bit driver..."
if [ -d "$DRIVER_DIR" ]; then
    echo "  → $DRIVER_DIR already exists, pulling latest..."
    git -C "$DRIVER_DIR" pull
else
    git clone https://github.com/Navigate-IO/morse-micro-64bit.git "$DRIVER_DIR"
fi

echo "[2/3] Cloning BATMAN-Script..."
if [ -d "$BATMAN_DIR" ]; then
    echo "  → $BATMAN_DIR already exists, pulling latest..."
    git -C "$BATMAN_DIR" pull
else
    git clone https://github.com/Navigate-IO/BATMAN-Script.git "$BATMAN_DIR"
fi

echo "[3/3] Cloning Recieve-Transfer-MCS-Test..."
if [ -d "$MCS_TEST_DIR" ]; then
    echo "  → $MCS_TEST_DIR already exists, pulling latest..."
    git -C "$MCS_TEST_DIR" pull
else
    git clone https://github.com/Navigate-IO/Recieve-Transfer-MCS-Test.git "$MCS_TEST_DIR"
fi

# ─── 2. Build Morse Micro driver ───
echo ""
echo "========================================="
echo "  Building Morse Micro driver"
echo "========================================="

KBUILD="/lib/modules/$(uname -r)/build"

if [ ! -d "$KBUILD" ]; then
    echo "ERROR: Kernel headers not found at $KBUILD"
    echo "Install them with:  sudo apt install raspberrypi-kernel-headers"
    exit 1
fi

echo "Cleaning previous build..."
make -C "$KBUILD" M="$DRIVER_DIR" clean

echo "Building modules..."
make -C "$KBUILD" M="$DRIVER_DIR" \
    CONFIG_WLAN_VENDOR_MORSE=m \
    CONFIG_MORSE_VENDOR_COMMAND=y \
    modules V=1

# Verify build output
for mod in "$DRIVER_DIR/dot11ah/dot11ah.ko" "$DRIVER_DIR/morse.ko"; do
    if [ ! -f "$mod" ]; then
        echo "ERROR: Expected module not found: $mod"
        exit 1
    fi
done
echo "Build successful!"

# ─── 3. Load Morse Micro modules ───
echo ""
echo "========================================="
echo "  Loading Morse Micro modules"
echo "========================================="

echo "Unblocking WiFi..."
sudo rfkill unblock wifi

echo "Removing old modules (if loaded)..."
sudo rmmod morse dot11ah 2>/dev/null || true

echo "Loading dependencies..."
sudo modprobe cfg80211
sudo modprobe mac80211
sudo modprobe crc7

echo "Loading dot11ah.ko..."
sudo insmod "$DRIVER_DIR/dot11ah/dot11ah.ko"

echo "Loading morse.ko..."
sudo insmod "$DRIVER_DIR/morse.ko"

echo ""
echo "========================================="
echo "  Done! Verifying loaded modules..."
echo "========================================="
lsmod | grep -E "morse|dot11ah" || echo "WARNING: Modules not showing in lsmod"
