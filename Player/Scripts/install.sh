#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${SUDO_USER:-${USER:-mario}}"
USER_ID="$(id -u "$USER_NAME")"
GROUP_NAME="$(id -gn "$USER_NAME")"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="koala-signage-agent.service"
CONFIG_PATH="/etc/koala-signage/config.json"
SERVICE_TEMPLATE="$PROJECT_DIR/Systemd/koala-signage-agent.service"
SERVICE_TMP="$(mktemp)"
trap 'rm -f "$SERVICE_TMP"' EXIT

sudo apt update
sudo apt install -y coreutils mpv

cd "$PROJECT_DIR"
swift build -c release

sudo install -d /opt/koala-signage /etc/koala-signage \
  /var/lib/koala-signage/content /var/lib/koala-signage/staging \
  /var/lib/koala-signage/playlists /var/lib/koala-signage/state \
  /var/log/koala-signage

sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo install -m 0755 .build/release/koala-signage-player /opt/koala-signage/koala-signage-player

if [[ ! -f "$CONFIG_PATH" ]]; then
  sudo install -m 0644 Resources/config.example.json "$CONFIG_PATH"
  echo "Created $CONFIG_PATH from the example configuration."
else
  echo "Preserving existing configuration at $CONFIG_PATH."
fi

sed \
  -e "s/^User=.*/User=$USER_NAME/" \
  -e "s/^Group=.*/Group=$GROUP_NAME/" \
  -e "s|^Environment=XDG_RUNTIME_DIR=.*|Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID|" \
  "$SERVICE_TEMPLATE" > "$SERVICE_TMP"
sudo install -m 0644 "$SERVICE_TMP" "/etc/systemd/system/$SERVICE_NAME"
sudo chown -R "$USER_NAME":"$GROUP_NAME" /var/lib/koala-signage /var/log/koala-signage

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo "Installation complete."
echo "Review $CONFIG_PATH and verify the service with:"
echo "sudo systemctl status $SERVICE_NAME"
echo "sudo journalctl -u $SERVICE_NAME -f"
