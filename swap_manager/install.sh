#!/bin/bash

# Create systemd service file for shell_swapper
cat << EOF > /etc/systemd/system/shell-swapper.service
[Unit]
Description=Dynamic Swap Management Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/shell_swapper.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# Copy shell_swapper script to system location
cp shell_swapper.sh /usr/local/bin/
chmod +x /usr/local/bin/shell_swapper.sh

# Reload systemd and enable/start service
systemctl daemon-reload
systemctl enable shell-swapper
systemctl start shell-swapper

echo "Shell Swapper service has been installed and started"
echo "Check status with: systemctl status shell-swapper"
