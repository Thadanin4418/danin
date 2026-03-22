#!/bin/zsh
set -euo pipefail
cd /Users/nin/Downloads/SoraninControlSuite
exec /usr/bin/python3 scripts/mac_control_relay_server.py
