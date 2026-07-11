#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${SUDO_USER:-mario}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sudo apt update
sudo apt install -y mpv

cd "$PROJECT_DIR"
swift build -c release

sudo install -d /opt/koala-signage /etc/koala-signage \
  /var/lib/koala-signage/content /var/lib/koala-signage/playlists \
  /var/log/koala-signage
sudo install -m 0755 .build/release/koala-signage-agent /opt/koala-signage/koala-signage-agent
sudo install -m 0644 config/config.example.json /etc/koala-signage/config.json
sudo install -m 0644 systemd/koala-signage-agent.service /etc/systemd/system/koala-signage-agent.service
sudo chown -R "$USER_NAME":"$USER_NAME" /var/lib/koala-signage /var/log/koala-signage

sudo systemctl daemon-reload
sudo systemctl enable koala-signage-agent.service

echo "Installation complete. Copy an MP4 into /var/lib/koala-signage/content and run:"
echo "sudo systemctl restart koala-signage-agent"
