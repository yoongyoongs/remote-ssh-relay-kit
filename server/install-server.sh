#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="remote-ssh-relay"
APP_DIR="/opt/remote-ssh-relay"
TUNNEL_USER="tunnel"

echo "[1/7] Install Node.js if missing"
if ! command -v node >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y nodejs
  else
    echo "Node.js is required on the relay server."
    exit 1
  fi
fi

echo "[2/7] Create relay app directory"
sudo mkdir -p "${APP_DIR}"

echo "[3/7] Create restricted tunnel user if needed"
if ! id "${TUNNEL_USER}" >/dev/null 2>&1; then
  sudo useradd --system --create-home --shell /bin/bash "${TUNNEL_USER}"
fi
sudo mkdir -p "/home/${TUNNEL_USER}/.ssh"
sudo touch "/home/${TUNNEL_USER}/.ssh/authorized_keys"
sudo chown -R "${TUNNEL_USER}:${TUNNEL_USER}" "/home/${TUNNEL_USER}/.ssh"
sudo chmod 700 "/home/${TUNNEL_USER}/.ssh"
sudo chmod 600 "/home/${TUNNEL_USER}/.ssh/authorized_keys"

echo "[4/7] Copy relay server files"
sudo mkdir -p "${APP_DIR}/server"
sudo cp "${SCRIPT_DIR}/relay-server.mjs" "${APP_DIR}/server/relay-server.mjs"
if [ -f "${SCRIPT_DIR}/relay.env.sample" ]; then
  sudo cp "${SCRIPT_DIR}/relay.env.sample" "${APP_DIR}/relay.env.sample"
fi

echo "[5/7] Write environment template"
if [ ! -f "${APP_DIR}/relay.env" ]; then
  sudo tee "${APP_DIR}/relay.env" >/dev/null <<'EOF'
API_BIND=0.0.0.0
API_PORT=8787
RELAY_HOST=106.13.171.166
RELAY_SSH_PORT=22
RELAY_USER=tunnel
ENROLL_CODES=CHANGE-ME
PORT_RANGE_START=24000
PORT_RANGE_END=24999
STATE_PATH=/opt/remote-ssh-relay/state/devices.json
AUTH_KEYS_PATH=/home/tunnel/.ssh/authorized_keys
LEASE_HOURS=24
EOF
fi

echo "[6/7] Install systemd service"
sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=Remote SSH Relay Enrollment API
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}/server
EnvironmentFile=${APP_DIR}/relay.env
ExecStart=/usr/bin/node ${APP_DIR}/server/relay-server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "[7/7] Reload systemd"
sudo systemctl daemon-reload

cat <<EOF

Relay files are installed.

Next steps:
1. Edit ${APP_DIR}/relay.env
2. Review ${SCRIPT_DIR}/sshd_config.sample and merge it into /etc/ssh/sshd_config
3. Enable the relay API:
   sudo systemctl enable --now ${SERVICE_NAME}
4. Restart sshd after applying the SSH forwarding settings

EOF
