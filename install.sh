#!/bin/bash
# Script: setup tun2socks di VPS (improved version)
# Pastikan: 
# 1. SOCKS proxy dari rumah sudah bisa diakses (via reverse SSH tunnel atau port forwarding)
# 2. VPS punya hak sudo

set -e

# === Konfigurasi ===
SOCKS_SERVER="127.0.0.1:1080"   # alamat SOCKS proxy rumah
TUN_IF="tun0"                   # nama interface TUN
TUN_IP="10.0.0.2/24"           # IP untuk interface TUN

# === Functions ===
cleanup() {
    echo "[!] Cleaning up..."
    sudo pkill tun2socks 2>/dev/null || true
    sudo ip link delete $TUN_IF 2>/dev/null || true
    # Restore original routes if backed up
    if [ -f /tmp/original_routes.bak ]; then
        echo "[!] Restoring original routes..."
        sudo ip route flush table main
        sudo ip route restore < /tmp/original_routes.bak
        rm -f /tmp/original_routes.bak
    fi
}

trap cleanup EXIT

# === Validasi prerequisites ===
if [ "$EUID" -eq 0 ]; then
    echo "❌ Jangan jalankan sebagai root langsung, gunakan sudo di dalam script"
    exit 1
fi

echo "[+] Checking SOCKS proxy connection..."
if ! timeout 5 nc -z ${SOCKS_SERVER%:*} ${SOCKS_SERVER#*:} 2>/dev/null; then
    echo "❌ SOCKS proxy tidak accessible di $SOCKS_SERVER"
    echo "    Pastikan reverse SSH tunnel sudah jalan:"
    echo "    ssh -N -R 1080:localhost:1080 user@vps_ip"
    exit 1
fi

# === Backup original routes ===
echo "[+] Backing up original routes..."
ip route save > /tmp/original_routes.bak

# === Install tun2socks ===
if ! command -v tun2socks >/dev/null 2>&1; then
    echo "[+] Installing tun2socks..."
    sudo apt update
    sudo apt install -y tun2socks
fi

# === Get network info ===
DEFAULT_GW=$(ip route | grep default | head -1 | awk '{print $3}')
DEFAULT_IF=$(ip route | grep default | head -1 | awk '{print $5}')
VPS_IP=$(ip route get 8.8.8.8 | grep src | head -1 | awk '{print $7}')

echo "[+] Network info:"
echo "    Default gateway: $DEFAULT_GW via $DEFAULT_IF"
echo "    VPS IP: $VPS_IP"

# === Cleanup existing interface ===
if ip link show $TUN_IF >/dev/null 2>&1; then
    echo "[+] Removing existing $TUN_IF interface..."
    sudo ip link delete $TUN_IF
fi

# === Buat interface TUN ===
echo "[+] Creating TUN interface $TUN_IF..."
sudo ip tuntap add dev $TUN_IF mode tun user $(whoami)
sudo ip addr add $TUN_IP dev $TUN_IF
sudo ip link set dev $TUN_IF up

# === Protect important connections ===
echo "[+] Protecting SSH and local connections..."
# Protect SSH connection to VPS
if [ -n "$SSH_CLIENT" ]; then
    SSH_SOURCE_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    echo "    Protecting SSH from $SSH_SOURCE_IP"
    sudo ip route add $SSH_SOURCE_IP via $DEFAULT_GW dev $DEFAULT_IF
fi

# Protect local networks
sudo ip route add 127.0.0.0/8 dev lo
sudo ip route add 10.0.0.0/8 via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true
sudo ip route add 172.16.0.0/12 via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true
sudo ip route add 192.168.0.0/16 via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true

# === Jalankan tun2socks ===
echo "[+] Starting tun2socks..."
sudo nohup tun2socks \
    -device $TUN_IF \
    -proxy socks5://$SOCKS_SERVER \
    -loglevel info > /tmp/tun2socks.log 2>&1 &

TUN2SOCKS_PID=$!
echo "    tun2socks PID: $TUN2SOCKS_PID"

# Wait for tun2socks to initialize
sleep 3

# Check if tun2socks is still running
if ! kill -0 $TUN2SOCKS_PID 2>/dev/null; then
    echo "❌ tun2socks failed to start. Check log:"
    cat /tmp/tun2socks.log
    exit 1
fi

# === Setup routing ===
echo "[+] Setting up routes..."
# Route all traffic through tun0 (split into two halves to avoid conflicts)
sudo ip route add 0.0.0.0/1 dev $TUN_IF metric 100
sudo ip route add 128.0.0.0/1 dev $TUN_IF metric 100

# === Test koneksi ===
echo "[+] Testing connection..."
echo -n "    Your VPS IP (direct): "
timeout 10 curl -s https://ifconfig.me || echo "timeout/failed"

echo -n "    Your IP via TUN (should be home IP): "
timeout 10 curl -s --interface $TUN_IF https://ifconfig.me || echo "timeout/failed"

# === Status ===
echo ""
echo "✅ Setup completed!"
echo ""
echo "📋 Usage:"
echo "   # Route specific command via TUN:"
echo "   curl --interface $TUN_IF https://example.com"
echo ""
echo "   # Check if tun2socks is running:"
echo "   ps aux | grep tun2socks"
echo ""
echo "   # View logs:"
echo "   tail -f /tmp/tun2socks.log"
echo ""
echo "   # Stop and cleanup:"
echo "   sudo pkill tun2socks && sudo ip link delete $TUN_IF"

# Don't run cleanup on successful exit
trap - EXIT
