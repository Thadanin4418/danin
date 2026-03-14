#!/bin/zsh
DIR="/Users/nin/Downloads/sora_license_server"
HOST="127.0.0.1"
PORT="8787"
URL="http://$HOST:$PORT/manager"
LOG_FILE="/tmp/sora-license-manager-server.log"
PID_FILE="$DIR/server.pid"
PREFILL_FILE="$DIR/data/manager-prefill-token.txt"
DEFAULT_ADMIN_TOKEN="mysecret123"
cd "$DIR" || exit 1
if [ -f "$HOME/.zshrc" ]; then
  source "$HOME/.zshrc"
fi

mkdir -p "$DIR/data"

echo "Sora License Manager"
echo
echo "This launcher starts the local license server and opens the manager page."
echo

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "A server is already running on port $PORT."
  echo "Press Enter to use default Admin Token: $DEFAULT_ADMIN_TOKEN"
  echo
  printf "Admin Token (optional): "
  IFS= read -r ADMIN_INPUT
  if [ -z "$ADMIN_INPUT" ]; then
    ADMIN_INPUT="$DEFAULT_ADMIN_TOKEN"
  fi
  if [ -n "$ADMIN_INPUT" ]; then
    printf "%s" "$ADMIN_INPUT" > "$PREFILL_FILE"
  else
    : > "$PREFILL_FILE"
  fi
  open "$URL"
  echo "Opening manager page..."
  echo
  printf "Press Enter to close this window..."
  IFS= read -r _
  exit 0
fi

echo "Enter Admin Token for the manager and admin routes."
echo "Press Enter to use default: $DEFAULT_ADMIN_TOKEN"
echo
printf "Admin Token: "
IFS= read -r ADMIN_INPUT
if [ -z "$ADMIN_INPUT" ]; then
  ADMIN_INPUT="$DEFAULT_ADMIN_TOKEN"
fi

echo
echo "Starting local server in background..."
if [ -n "$ADMIN_INPUT" ]; then
  nohup env ADMIN_TOKEN="$ADMIN_INPUT" node "$DIR/server.mjs" >"$LOG_FILE" 2>&1 &
else
  nohup node "$DIR/server.mjs" >"$LOG_FILE" 2>&1 &
fi

SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

for _ in {1..20}; do
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Server started."
  echo "PID : $SERVER_PID"
  echo "Log : $LOG_FILE"
  echo "Page: $URL"
  echo
  if [ -n "$ADMIN_INPUT" ]; then
    printf "%s" "$ADMIN_INPUT" > "$PREFILL_FILE"
  else
    : > "$PREFILL_FILE"
  fi
  open "$URL"
else
  echo "Server did not start correctly."
  echo "Check log:"
  echo "  $LOG_FILE"
fi

echo
printf "Press Enter to close this window..."
IFS= read -r _
