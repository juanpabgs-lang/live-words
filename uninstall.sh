#!/bin/bash
# Remove Live Words completely.
#
#   curl -fsSL https://raw.githubusercontent.com/juanpabgs-lang/live-words/main/uninstall.sh | bash
set -uo pipefail

pkill -x LiveWords 2>/dev/null
for d in /Applications "$HOME/Applications"; do
  app="$d/LiveWords.app"
  if [ -d "$app" ]; then
    "$app/Contents/MacOS/LiveWords" --unregister-login 2>/dev/null  # remove its own login item
    rm -rf "$app" && echo "removed $app"
  fi
done
defaults delete com.jpbarrios.livewords >/dev/null 2>&1
rm -f "$HOME/Library/Logs/LiveWords.log"
echo "Live Words uninstalled."
