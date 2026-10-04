#!/bin/bash
# Live Words installer.
#
#   curl -fsSL https://raw.githubusercontent.com/juanpabgs-lang/live-words/main/install.sh | bash
#
# Builds the app from source on your Mac (so macOS trusts it), installs it to
# /Applications, and launches it. Safe to re-run — that's also how you update.
set -euo pipefail

REPO="juanpabgs-lang/live-words"
bold() { printf "\n\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m%s\033[0m\n" "$*"; exit 1; }

bold "Live Words installer"

# 1. macOS 26 (Tahoe) or newer — the live speech engine is new in macOS 26.
ver=$(sw_vers -productVersion)
[ "${ver%%.*}" -ge 26 ] || fail "Live Words needs macOS 26 (Tahoe) or newer. This Mac has macOS $ver."

# 2. Apple's Command Line Tools (the Swift compiler). One-time install.
if ! xcrun --find swiftc >/dev/null 2>&1; then
  bold "Installing Apple's Command Line Tools (one time, needed to build the app)…"
  xcode-select --install 2>/dev/null || true
  fail "A window popped up — click Install, wait until it finishes, then run the same command again."
fi

# 3. Get the source: use this folder if run from a clone, otherwise download it.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/LiveWords.swift" ]; then
  src="$here"
else
  src="$(mktemp -d)/live-words"
  mkdir -p "$src"
  bold "Downloading Live Words…"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" | tar xz -C "$src" --strip-components 1
fi

# 4. Build + install + launch.
bold "Building (takes ~30 seconds)…"
"$src/build.sh" install

bold "✅ Live Words is installed and running."
cat <<'EOF'

Next:
  • macOS will ask to let "Live Words" use the microphone → click Allow.
  • Look for the speech-bubble icon in your menu bar.
  • Start dictating with your dictation app (OpenWhispr, Wispr Flow or
    superwhisper) — a bar with your words appears at the bottom of the screen.

It starts automatically when you log in. Logs: ~/Library/Logs/LiveWords.log
EOF
