#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$DIR/remote-ssh.sh"
exec "$DIR/remote-ssh.sh" "$DIR/config.ini"
