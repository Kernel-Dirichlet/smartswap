#!/bin/bash
set -e  # Exit immediately on error

if [ -z "$1" ]; then
    echo "ERROR: No package directory specified. Run this script with sudo after installation."
    exit 1
fi

PKGDIR="$1"

echo "Creating systemd service file..."
cat << 'EOF' > "$PKGDIR/etc/systemd/system/smartswap-daemon.service"
[Unit]
Description=Dynamic Swap Management Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/lib/smartswap/smartswap_daemon.sh
Restart=no
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "Service file created successfully."

echo "Creating installation directory..."
mkdir -p "$PKGDIR/usr/lib/smartswap/"

echo "Setting up smartswap_daemon script..."
chmod +x "$PKGDIR/usr/lib/smartswap/smartswap_daemon.sh"

echo "✅ Setup complete. Run 'sudo systemctl enable --now smartswap-daemon' to start."

