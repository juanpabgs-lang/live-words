#!/bin/bash
# Make OpenWhispr much better at names (companies, products, people).
#
#   ./tune.sh                                  # model + correction pass, keeps your dictionary
#   ./tune.sh --words "Palantir, Higgsfield"   # also REPLACES your dictionary with these words
#   ./tune.sh --restore <backup folder>        # undo: put a backup back
#
# Needs: OpenWhispr set to Groq with your own API key ("Bring your own key"),
# and Node.js (https://nodejs.org or `brew install node`).
# Always backs up OpenWhispr's settings first. OpenWhispr is closed for a few
# seconds and reopened.
set -euo pipefail
cd "$(dirname "$0")"

OW="$HOME/Library/Application Support/open-whispr"
OW_PROC="OpenWhispr.app/Contents/MacOS/OpenWhispr"
bold() { printf "\n\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m%s\033[0m\n" "$*"; exit 1; }

WORDS=""; RESTORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --words) WORDS="${2:-}"; shift 2 ;;
    --restore) RESTORE="${2:-}"; shift 2 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[ -d "$OW/Local Storage/leveldb" ] || fail "OpenWhispr settings not found. Install and open OpenWhispr once first."

quit_openwhispr() {
  osascript -e 'tell application "OpenWhispr" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -f "$OW_PROC" >/dev/null || return 0; sleep 0.5; done
  fail "OpenWhispr didn't quit — nothing was changed. Quit it from its menu and try again."
}

if [ -n "$RESTORE" ]; then
  [ -d "$RESTORE/Local Storage" ] || fail "Not a backup folder: $RESTORE"
  quit_openwhispr
  rm -rf "$OW/Local Storage" && cp -R "$RESTORE/Local Storage" "$OW/"
  [ -f "$RESTORE/transcriptions.db" ] && cp "$RESTORE/transcriptions.db" "$OW/"
  open -a OpenWhispr
  bold "✅ Restored OpenWhispr settings from $RESTORE"
  exit 0
fi

command -v node >/dev/null || fail "Node.js is needed. Install it from https://nodejs.org (or: brew install node), then run this again."
if [ ! -d node_modules/classic-level ]; then
  bold "Installing helper (one time)…"
  npm install --silent --no-audit --no-fund >/dev/null
fi

quit_openwhispr
BK="$HOME/OpenWhispr-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
cp -R "$OW/Local Storage" "$BK/"
[ -f "$OW/transcriptions.db" ] && cp "$OW/transcriptions.db" "$BK/"

DICT=$(node apply.js "$OW/Local Storage/leveldb" prompt.txt "$WORDS")

# Keep OpenWhispr's dictionary table in sync with the new word list.
if [ -n "$DICT" ] && [ -f "$OW/transcriptions.db" ]; then
  SQL=$(printf '%s' "$DICT" | python3 -c "import json,sys; print('DELETE FROM custom_dictionary; ' + ' '.join(\"INSERT OR IGNORE INTO custom_dictionary(word) VALUES('%s');\" % w.replace(\"'\", \"''\") for w in json.load(sys.stdin)))")
  sqlite3 "$OW/transcriptions.db" "$SQL"
fi

open -a OpenWhispr
bold "✅ OpenWhispr tuned."
echo "  • Speech model: Whisper Large v3"
echo "  • Name-fixing pass: on (Groq · GPT-OSS 120B)"
[ -n "$DICT" ] && echo "  • Dictionary: $DICT"
echo
echo "Backup saved at: $BK"
echo "Undo anytime:    ./tune.sh --restore \"$BK\""
