#!/bin/sh
# chrome-remote skill installer — the one command:
#
#   npx skills add random-react-dev/chrome-remote     (via GitHub)
#   curl -fsSL http://34.71.214.90/skill/install.sh | sh
#
# Installs the skill into the local agent skill folders (~/.claude/skills,
# ~/.codex/skills, .agents/skills). Then tell your agent: "set up chrome-remote".
set -eu

TMP=$(mktemp -d /tmp/crs-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "chrome-remote: downloading skill..."
curl -fsSL http://34.71.214.90/skill/chrome-remote.tar.gz -o "$TMP/skill.tgz"
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
echo "chrome-remote: next step — tell your agent:  set up chrome-remote"
