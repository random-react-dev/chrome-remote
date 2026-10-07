#!/bin/zsh
# agentd.sh — Mac B: the silent agent daemon (LaunchAgent com.user.chromeremote.agentd).
#
# Every POLL_SECS: heartbeat to the VM (chrome/port/idle state), poll for a job.
# Per job: launch the headless agent (codex or claude) with OUR LLM API and the
# brief (AGENT.md) + the job instruction; the agent does the work and uploads
# artifacts with `agentd.sh upload`; agentd uploads the transcript and reports done.
#
# One-shot subcommands (also used by the agent itself):
#   ./agentd.sh status                  # chrome/port/idle JSON
#   ./agentd.sh upload <job> <file> [name]
#
# All logging: ~/chrome-remote-agentd.log

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR" || exit 1
source ./conf
LOG="$HOME/chrome-remote-agentd.log"
JOBS_DIR="$DIR/jobs"
mkdir -p "$JOBS_DIR"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
jlog() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$1" "${@:2}" >> "$LOG"; }

AGENT_BIN=""
command -v codex  >/dev/null 2>&1 && AGENT_BIN=codex
[ -z "$AGENT_BIN" ] && command -v claude >/dev/null 2>&1 && AGENT_BIN=claude
# Dedicated CODEX_HOME (the user's own ~/.codex stays as-is): model comes from conf.
[ "$AGENT_BIN" = codex ] && { mkdir -p "$DIR/.codex" && printf 'model = "%s"\n' "$LLM_MODEL" > "$DIR/.codex/config.toml"; }

status_json() {
  local pid flag port idle
  pid=""
  for p in $(pgrep -x "Google Chrome" 2>/dev/null); do
    ps -o command= -p "$p" 2>/dev/null | grep -q -- "--type=" || { pid="$p"; break; }
  done
  flag=no
  [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | grep -q -- "--remote-debugging-port=" && flag=yes
  if curl -s --max-time 2 "http://127.0.0.1:$CDP_PORT/json/version" 2>/dev/null | grep -q Browser; then port=up; else port=down; fi
  idle=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
  printf '{"agent":"%s","agentBin":"%s","model":"%s","chrome":{"pid":"%s","flag":"%s","port":"%s"},"idle":%s,"host":"%s"}' \
    "$NODE" "${AGENT_BIN:-none}" "$LLM_MODEL" "${pid:-none}" "$flag" "$port" "${idle:-0}" "$(hostname)"
}

upload_file() { # <job> <file> [name]  (JSON via temp file — b64 can be >1MB, argv is not)
  local n="${3:-$(basename "$2")}" jf ok
  jf=$(mktemp /tmp/.cr-up.XXXXXX)
  python3 -c 'import sys, json, base64
job, name, f = sys.argv[1], sys.argv[2], sys.argv[3]
b64 = base64.b64encode(open(f, "rb").read()).decode()
print(json.dumps({"job": job, "name": name, "b64": b64}))' "$1" "$n" "$2" > "$jf" 2>/dev/null \
    || { rm -f "$jf"; return 1; }
  if [ $(wc -c < "$jf" | tr -d ' ') -gt 15500000 ]; then
    rm -f "$jf"; log "upload skipped (too large): $2"; return 1
  fi
  ok=$(curl -s -m 120 -X POST "$VM_BASE/agent/upload?t=$NODE_TOKEN" \
    -H 'Content-Type: application/json' -d @"$jf" 2>/dev/null)
  rm -f "$jf"
  log "upload job=$1 name=$n resp=${ok:-none}"
  echo "$ok" | grep -q '"ok":true'
}

case "${1:-}" in
  status)
    echo "$(status_json)"
    exit 0
    ;;
  upload)
    shift
    [ $# -ge 2 ] || { echo "usage: agentd.sh upload <job> <file> [name]" >&2; exit 1; }
    if upload_file "$1" "$2" "${3:-}"; then echo "uploaded $2"; exit 0
    else echo "upload failed" >&2; exit 1; fi
    ;;
  selfjob)
    shift
    text="$*"
    [ -n "$text" ] || { echo "usage: agentd.sh selfjob \"instruction\"" >&2; exit 1; }
    sf=$(mktemp /tmp/.cr-selfjob.XXXXXX)
    python3 -c 'import sys, json; print(json.dumps({"instruction": sys.argv[1]}))' "$text" > "$sf"
    r=$(curl -s -m 15 -X POST "$VM_BASE/agent/selfjob?t=$NODE_TOKEN" \
      -H 'Content-Type: application/json' -d @"$sf")
    rm -f "$sf"
    echo "$r"
    ;;
  done)
    shift
    [ $# -ge 2 ] || { echo "usage: agentd.sh done <job> <ok|fail> [note]" >&2; exit 1; }
    df=$(mktemp /tmp/.cr-done.XXXXXX)
    python3 -c 'import sys, json
note = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
print(json.dumps({"job": sys.argv[1], "status": sys.argv[2], "note": note}))' \
      "$1" "$2" "${3:-}" > "$df"
    r=$(curl -s -m 15 -X POST "$VM_BASE/agent/done?t=$NODE_TOKEN" \
      -H 'Content-Type: application/json' -d @"$df")
    rm -f "$df"
    echo "$r"
    ;;
esac

[ -n "${NODE_TOKEN:-}" ] || log "WARN: NODE_TOKEN empty — agentd will not poll (fix conf)"

run_job() {
  local jid="$1" instruction="$2"
  local jdir="$JOBS_DIR/$jid"
  mkdir -p "$jdir"
  {
    cat "$DIR/AGENT.md"
    echo
    echo "=== JOB $jid ==="
    echo "Job directory: $jdir (write every artifact you want uploaded there)"
    echo "Upload a file:  $DIR/agentd.sh upload $jid <file>"
    echo
    echo "Instruction:"
    echo "$instruction"
    echo
    echo "Make your final line exactly:  RESULT: OK <short summary>   (or RESULT: FAIL <reason>)"
  } > "$jdir/prompt.txt"
  jlog "$jid" "start agent=${AGENT_BIN:-NONE} prompt=$(wc -c < "$jdir/prompt.txt" | tr -d ' ')b timeout=${JOB_TIMEOUT_SECS}s"
  local rc=124
  if [ "$AGENT_BIN" = codex ]; then
    perl -e 'alarm shift; exec @ARGV' "$JOB_TIMEOUT_SECS" \
      env CODEX_HOME="$DIR/.codex" OPENAI_BASE_URL="$LLM_BASE" OPENAI_API_KEY="$LLM_KEY" \
      codex exec --dangerously-bypass-approvals-and-sandbox -m "$LLM_MODEL" "$(cat "$jdir/prompt.txt")" \
      > "$jdir/transcript.txt" 2>&1
    rc=$?
  elif [ "$AGENT_BIN" = claude ]; then
    perl -e 'alarm shift; exec @ARGV' "$JOB_TIMEOUT_SECS" \
      env CLAUDE_CONFIG_DIR="$DIR/.claude" ANTHROPIC_BASE_URL="${LLM_BASE%/v1}" ANTHROPIC_AUTH_TOKEN="$LLM_KEY" \
      claude -p --dangerously-skip-permissions "$(cat "$jdir/prompt.txt")" \
      > "$jdir/transcript.txt" 2>&1
    rc=$?
  else
    jlog "$jid" "no headless agent binary (codex/claude) on this Mac"
    echo "RESULT: FAIL no headless agent (codex or claude) found on this Mac" > "$jdir/transcript.txt"
    rc=1
  fi
  jlog "$jid" "agent exit=$rc transcript=$(wc -c < "$jdir/transcript.txt" 2>/dev/null | tr -d ' ')b"
  local tfile="$jdir/transcript.txt"
  if [ -s "$tfile" ] && [ $(wc -c < "$tfile" | tr -d ' ') -gt 500000 ]; then
    tail -c 500000 "$tfile" > "$jdir/transcript-tail.txt"
    upload_file "$jid" "$jdir/transcript-tail.txt" "transcript-tail.txt"
  elif [ -s "$tfile" ]; then
    upload_file "$jid" "$tfile" "transcript.txt"
  fi
  local resline status
  resline=$(grep -E '^RESULT: (OK|FAIL)' "$tfile" 2>/dev/null | tail -1)
  if echo "$resline" | grep -q '^RESULT: OK'; then status=ok; else status=fail; fi
  jlog "$jid" "done status=$status (${resline:-no RESULT line, exit=$rc})"
  printf '%s' "${resline:-agent exit=$rc, no RESULT line in transcript}" | \
    python3 -c 'import sys,json; print(json.dumps({"job": sys.argv[1], "status": sys.argv[2], "note": sys.stdin.read()[:2000]}))' \
      "$jid" "$status" > "$jdir/done.json" 2>/dev/null
  curl -s -m 15 -X POST "$VM_BASE/agent/done?t=$NODE_TOKEN" \
    -H 'Content-Type: application/json' -d @"$jdir/done.json" >> "$LOG" 2>&1
}

log "agentd started pid=$$ node=$NODE agent=${AGENT_BIN:-NONE} vm=$VM_BASE model=$LLM_MODEL"
while true; do
  curl -s -m 10 -X POST "$VM_BASE/agent/heartbeat?t=$NODE_TOKEN" \
    -H 'Content-Type: application/json' -d "$(status_json)" >> "$LOG" 2>&1
  poll=$(curl -s -m 10 "$VM_BASE/agent/poll?t=$NODE_TOKEN" 2>>"$LOG") || poll=""
  jid=$(printf '%s' "$poll" | python3 -c 'import sys,json
try:
    j = json.load(sys.stdin).get("job")
    print(j["id"] if j else "")
except Exception:
    print("")' 2>/dev/null)
  if [ -n "$jid" ]; then
    instruction=$(printf '%s' "$poll" | python3 -c 'import sys,json; print(json.load(sys.stdin)["job"]["instruction"])' 2>/dev/null)
    run_job "$jid" "$instruction"
  fi
  # jitter the poll (±25%) so the traffic pattern is not metronome-regular
  sleep $(( POLL_SECS + (RANDOM % (POLL_SECS / 2 + 1)) - POLL_SECS / 4 ))
done
