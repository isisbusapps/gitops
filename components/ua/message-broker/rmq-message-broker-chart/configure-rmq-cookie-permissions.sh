#!/usr/bin/env sh

set -eu

SOURCE="/secret/.erlang.cookie"
TARGET="/var/lib/rabbitmq/.erlang.cookie"

echo "Copying Erlang cookie..."

if [ ! -f "$SOURCE" ]; then
  echo "Error: $SOURCE does not exist"
  exit 1
fi

cp "$SOURCE" "$TARGET"
chown 999:999 "$TARGET"
chmod 400 "$TARGET"

echo "Erlang cookie installed successfully."