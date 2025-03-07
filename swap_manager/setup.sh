#!/bin/bash

# Create systemd service file for shell_swapper
echo "Creating systemd service file..."
cat << 'EOF' > /etc/systemd/system/smartswap.service
[Unit]
Description=Dynamic Swap Management Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/smartswap_daemon.sh
Restart=no
RestartSec=60
User=root

[Install]
WantedBy=multi-user.target
EOF

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create service file"
    exit 1
fi
echo "Service file created successfully"

# Copy smartswap script to system location
echo "Installing smartswap manager..."
if ! cp smartswap_daemon.sh /usr/local/bin/; then
    echo "ERROR: Failed to copy script to /usr/local/bin/"
    exit 1
fi

if ! chmod +x /usr/local/bin/smartswap_daemon.sh; then
    echo "ERROR: Failed to make script executable"
    exit 1
fi
echo "Script installed successfully"

# Reload systemd and enable/start service
echo "Reloading systemd daemon..."
if ! systemctl daemon-reload; then
    echo "ERROR: Failed to reload systemd daemon"
    exit 1
fi
echo "Systemd daemon reloaded successfully"

echo "Enabling shell-swapper service..."
if ! systemctl enable smartswap; then
    echo "ERROR: Failed to enable shell-swapper service"
    exit 1
fi
echo "Service enabled successfully"

echo "Starting shell-swapper service..."
if ! systemctl start smartswap; then
    echo "ERROR: Failed to start shell-swapper service"
    exit 1
fi
echo "SmartSwap installation: success!"
echo "SmartSwap Service started successfully"
