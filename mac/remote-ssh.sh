#!/bin/bash
set -euo pipefail

CONFIG_PATH="${1:-$(cd "$(dirname "$0")" && pwd)/config.ini}"
RUNTIME_DIR="${HOME}/Library/Application Support/RemoteSshRelay"
DEVICE_KEY="${RUNTIME_DIR}/device_key"
mkdir -p "$RUNTIME_DIR"

read_ini() {
  local key="$1"
  grep -E "^${key}=" "$CONFIG_PATH" | head -n1 | cut -d'=' -f2-
}

make_device_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c1-8
    return
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -V >/dev/null 2>&1; then
    python3 - <<'PY'
import uuid
print(str(uuid.uuid4()).replace('-', '')[:8])
PY
    return
  fi
  printf '%08x\n' $(( (RANDOM << 16) | RANDOM )) | cut -c1-8
}

json_get() {
  local key="$1"
  if command -v python3 >/dev/null 2>&1 && python3 -V >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$key"
    return
  fi
  if command -v python >/dev/null 2>&1 && python -V >/dev/null 2>&1; then
    python -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$key"
    return
  fi
  if command -v ruby >/dev/null 2>&1; then
    ruby -rjson -e 'print JSON.parse(STDIN.read).fetch(ARGV[0])' "$key"
    return
  fi
  sed -nE "s/.*\"${key}\":\"?([^\",}]+)\"?.*/\\1/p"
}

RELAY_HOST="$(read_ini RELAY_HOST)"
RELAY_SSH_PORT="$(read_ini RELAY_SSH_PORT)"
ENROLL_API="$(read_ini ENROLL_API)"
BOOTSTRAP_API="$(read_ini BOOTSTRAP_API)"
BOOTSTRAP_TOKEN="$(read_ini BOOTSTRAP_TOKEN)"
ENROLL_CODE="$(read_ini ENROLL_CODE)"
ADMIN_PUBLIC_KEY="$(read_ini ADMIN_PUBLIC_KEY)"
DRY_RUN="$(read_ini DRY_RUN)"

# 检查是否应该使用 Bootstrap 模式
if [ -z "$ENROLL_CODE" ] || [ "$ENROLL_CODE" = "CHANGE-ME" ] || [ -z "$ADMIN_PUBLIC_KEY" ] || [ "$ADMIN_PUBLIC_KEY" = "CHANGE-ME" ]; then
  if [ -z "$BOOTSTRAP_TOKEN" ] || [ "$BOOTSTRAP_TOKEN" = "CHANGE-ME" ]; then
    printf '错误: 配置文件缺少 ENROLL_CODE/ADMIN_PUBLIC_KEY，且未提供有效的 BOOTSTRAP_TOKEN。\n' >&2
    exit 1
  fi
  if [ -z "$BOOTSTRAP_API" ]; then
    printf '错误: 缺少 BOOTSTRAP_API 配置。\n' >&2
    exit 1
  fi
  
  step "[0/7] 正在向中继服务器获取动态配置..."
  DEVICE_NAME="$(scutil --get ComputerName 2>/dev/null || hostname)"
  LOCAL_USER="$(id -un)"
  
  if [ "$DRY_RUN" = "true" ]; then
    ENROLL_CODE="AUTO-DRYRUN"
    ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunAdminKey remote-ssh-relay-admin"
  else
    PAYLOAD="$(printf '{"bootstrap_token":"%s","device_name":"%s","os_type":"macos","local_user":"%s","launcher_version":"0.1.0"}' "$BOOTSTRAP_TOKEN" "$DEVICE_NAME" "$LOCAL_USER")"
    RESPONSE="$(curl -fsSL -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$BOOTSTRAP_API")"
    
    OK_STATUS="$(printf '%s' "$RESPONSE" | json_get ok | tr '[:upper:]' '[:lower:]')"
    if [ "$OK_STATUS" != "true" ]; then
      ERROR_MSG="$(printf '%s' "$RESPONSE" | json_get message)"
      printf '获取连接配置失败: %s\n' "$ERROR_MSG" >&2
      exit 1
    fi
    
    ENROLL_CODE="$(printf '%s' "$RESPONSE" | json_get enroll_code)"
    ADMIN_PUBLIC_KEY="$(printf '%s' "$RESPONSE" | json_get admin_public_key)"
    
    # 动态覆盖来自服务器的中继设置
    RELAY_HOST_NEW="$(printf '%s' "$RESPONSE" | json_get relay_host)"
    if [ -n "$RELAY_HOST_NEW" ]; then RELAY_HOST="$RELAY_HOST_NEW"; fi
    
    RELAY_SSH_PORT_NEW="$(printf '%s' "$RESPONSE" | json_get relay_ssh_port)"
    if [ -n "$RELAY_SSH_PORT_NEW" ]; then RELAY_SSH_PORT="$RELAY_SSH_PORT_NEW"; fi
    
    RELAY_USER_NEW="$(printf '%s' "$RESPONSE" | json_get relay_user)"
    if [ -n "$RELAY_USER_NEW" ]; then RELAY_USER="$RELAY_USER_NEW"; fi
  fi
fi


step() {
  printf '%s\n' "$1"
}

step "[1/7] 检查 ssh 客户端"
command -v ssh >/dev/null 2>&1

step "[2/7] 检查并开启远程登录"
if [ "$DRY_RUN" = "true" ]; then
  :
else
  if ! sudo systemsetup -getremotelogin | grep -qi "On"; then
    sudo systemsetup -setremotelogin on
  fi
fi

step "[3/7] 检查本机 SSH 监听"
if [ "$DRY_RUN" = "true" ]; then
  :
else
  nc -z 127.0.0.1 22
fi

step "[4/7] 生成设备密钥"
if [ ! -f "$DEVICE_KEY" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    printf '%s\n' "dry-run-private-key" > "$DEVICE_KEY"
    printf '%s\n' "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunDeviceKey remote-ssh-relay" > "${DEVICE_KEY}.pub"
  else
    ssh-keygen -q -t ed25519 -N "" -f "$DEVICE_KEY"
  fi
fi

step "[5/7] 写入管理员公钥"
mkdir -p "${HOME}/.ssh"
touch "${HOME}/.ssh/authorized_keys"
grep -qxF "$ADMIN_PUBLIC_KEY" "${HOME}/.ssh/authorized_keys" || printf '%s\n' "$ADMIN_PUBLIC_KEY" >> "${HOME}/.ssh/authorized_keys"

step "[6/7] 向中转服务器注册设备"
DEVICE_ID="mac-$(make_device_id)"
LOCAL_USER="$(id -un)"
DEVICE_NAME="$(scutil --get ComputerName 2>/dev/null || hostname)"
PUBLIC_KEY="$(cat "${DEVICE_KEY}.pub")"

if [ "$DRY_RUN" = "true" ]; then
  RESPONSE="$(printf '{"connect_command":"ssh -p 24137 %s@%s","remote_port":24137,"relay_user":"tunnel"}' "$LOCAL_USER" "$RELAY_HOST")"
else
  PAYLOAD="$(printf '{"enroll_code":"%s","device_id":"%s","device_name":"%s","device_public_key":"%s","os_type":"macos","local_user":"%s","ssh_ready":true,"launcher_version":"0.1.0"}' "$ENROLL_CODE" "$DEVICE_ID" "$DEVICE_NAME" "$PUBLIC_KEY" "$LOCAL_USER")"
  RESPONSE="$(curl -fsSL -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$ENROLL_API")"
  
  OK_STATUS="$(printf '%s' "$RESPONSE" | json_get ok | tr '[:upper:]' '[:lower:]')"
  if [ "$OK_STATUS" != "true" ]; then
    ERROR_MSG="$(printf '%s' "$RESPONSE" | json_get message)"
    printf '设备注册失败: %s\n' "$ERROR_MSG" >&2
    exit 1
  fi
fi

if [ "$DRY_RUN" = "true" ]; then
  CONNECT_COMMAND="ssh -p 24137 ${LOCAL_USER}@${RELAY_HOST}"
  REMOTE_PORT="24137"
  RELAY_USER="tunnel"
else
  CONNECT_COMMAND="$(printf '%s' "$RESPONSE" | json_get connect_command)"
  REMOTE_PORT="$(printf '%s' "$RESPONSE" | json_get remote_port)"
  RELAY_USER="$(printf '%s' "$RESPONSE" | json_get relay_user)"
fi

step "[7/7] 启动反向 SSH 隧道"
if [ "$DRY_RUN" != "true" ]; then
  ssh -f -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -i "$DEVICE_KEY" \
    -p "$RELAY_SSH_PORT" \
    -R "0.0.0.0:${REMOTE_PORT}:127.0.0.1:22" \
    "${RELAY_USER}@${RELAY_HOST}"
fi

printf '\n连接已经准备完成。\n请把下面这条命令发给管理员：\n%s\n' "$CONNECT_COMMAND"
