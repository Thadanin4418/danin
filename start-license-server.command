#!/bin/zsh
DIR="/Users/nin/Downloads/sora_license_server"
cd "$DIR" || exit 1
if [ -f "$HOME/.zshrc" ]; then
  source "$HOME/.zshrc"
fi

echo "Sora License Server"
echo
echo "Enter Admin Token for the web admin panel."
echo "Leave it blank and press Enter if you want to start without admin routes."
echo
printf "Admin Token: "
IFS= read -r ADMIN_INPUT

echo
if [ -n "$ADMIN_INPUT" ]; then
  echo "Starting server with admin routes enabled..."
  export ADMIN_TOKEN="$ADMIN_INPUT"
else
  echo "Starting server without admin routes..."
fi

echo
echo "Health: http://127.0.0.1:8787/health"
echo "Admin : http://127.0.0.1:8787/admin"
echo

exec node "$DIR/server.mjs"
