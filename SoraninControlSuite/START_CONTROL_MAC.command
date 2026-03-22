#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
BUILD_SCRIPT="${REPO_ROOT}/ReelsNativeApp/build_native_app.sh"
APP_DIR="${SORANIN_APP_DIR:-${HOME}/Desktop/Soranin.app}"
STATUS_URL="http://127.0.0.1:8765/status"

if [[ ! -f "${BUILD_SCRIPT}" ]]; then
  echo "Missing build script: ${BUILD_SCRIPT}"
  exit 1
fi

echo "== Soranin iPhone <-> Mac Control =="
echo
echo "[1/4] Building Mac app..."
"${BUILD_SCRIPT}"
echo
echo "[2/4] Opening Mac app..."
open "${APP_DIR}"

echo
echo "[3/4] Waiting for local control server..."
server_ok=0
for _ in {1..20}; do
  if curl -fsS "${STATUS_URL}" >/dev/null 2>&1; then
    server_ok=1
    break
  fi
  sleep 1
done

if [[ "${server_ok}" -ne 1 ]]; then
  echo "Server did not respond at ${STATUS_URL}"
  exit 1
fi

LAN_IP="$(
python3 - <<'PY'
import socket

def detect_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        sock.close()

print(detect_ip())
PY
)"

echo "[4/4] Ready"
echo
echo "Mac app:"
echo "  ${APP_DIR}"
echo
echo "Local server:"
echo "  ${STATUS_URL}"
echo
echo "Use this in iPhone app > Control Mac > Server URL:"
echo "  http://${LAN_IP}:8765"
echo
echo "Next on iPhone:"
echo "  1. Open soranin"
echo "  2. Tap Control Mac"
echo "  3. Paste: http://${LAN_IP}:8765"
echo "  4. Tap Load Mac"
echo "  5. Choose Chrome Name, Page, and Folders"
echo "  6. Tap Preflight or Run Facebook Post"
echo
