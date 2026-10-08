#!/bin/zsh
# collect.sh — chrome-remote bundle collector (the "other PC"). STREAMING v2.
#
# Packages the real Chrome's profile + Safe Storage key (+ optionally Chrome.app)
# the proven clone-sync way, then uploads the encrypted bundle to the VM agent
# API in 11MB parts. v2 STREAMS instead of staging: tar reads the live tree
# (read-only), pipes through AES-256 into split parts, and every part is
# uploaded and DELETED as soon as it is complete — peak disk is the sqlite
# backups + two parts (~a few hundred MB), no multi-GB temp copies ever exist.
#
# Safe while the user's Chrome is running: everything is READ-only.
#
# Usage: collect.sh [--job <id>] [--minimal] [--full] [--no-upload]
#   --job <id>     use an existing job id (else claim one via selfjob)
#   --minimal      profile+DBs+key only (skip Chrome.app)
#   --full         force Chrome.app even on refreshes
#   --no-upload    build the bundle locally only (dry runs / testing)
#
# The FIRST clone ships Chrome.app; refreshes are minimal (apply.sh keeps it).
#
# Output contract (the last line is what other agents parse):
#   JOB <id>                   early, once a job is claimed
#   BUNDLE OK <name> <sha256>  success (bundle uploaded, job closed)
#   COLLECT FAIL <reason>      failure (job closed with status=fail if claimed)

set -uo pipefail
setopt null_glob
RUN="${CHROME_REMOTE_RUN:-$(cd "$(dirname "$0")" && pwd)}"
cd "$RUN"
# shellcheck disable=SC1091
source ./conf

JOB="" MINIMAL=0 UPLOAD=1 FORCE_FULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --job) JOB="${2:-}"; shift 2 ;;
    --minimal) MINIMAL=1; shift ;;
    --full) FORCE_FULL=1; shift ;;
    --no-upload) UPLOAD=0; shift ;;
    *) echo "unknown flag: $1"; exit 2 ;;
  esac
done
# refresh policy: first clone ships Chrome.app; later ones are minimal unless --full
if [ $FORCE_FULL -eq 0 ] && [ -f "$RUN/.full-clone-done" ]; then
  MINIMAL=1
  echo "refresh mode: minimal bundle (Chrome.app already shipped once)"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cr-collect.XXXXXX")
[ "$UPLOAD" = 1 ] && trap 'rm -rf "$WORK"' EXIT   # --no-upload keeps the bundle
mkdir -p "$WORK/db" "$WORK/extra"
log() { echo "==== $*"; }

STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$( (scutil --get LocalHostName 2>/dev/null || hostname) | tr -c 'A-Za-z0-9-_' '_' )
SAFE="clone-sync-${NODE//-/_}"
CLAIMED=""
die() { # <reason>
  echo "COLLECT FAIL $*"
  if [ "$UPLOAD" = 1 ] && [ -n "$CLAIMED" ]; then
    zsh "$RUN/agentd.sh" done "$CLAIMED" fail "$*" >/dev/null 2>&1 || true
  fi
  exit 1
}

# helper: upload one file to the current job (JSON via temp file — b64 is big)
up_part() { # <name> <file>
  local jf i ok perr
  jf=$(mktemp /tmp/.cr-part.XXXXXX)
  perr=$(python3 -c 'import sys, json, base64
job, name, f = sys.argv[1], sys.argv[2], sys.argv[3]
b64 = base64.b64encode(open(f, "rb").read()).decode()
print(json.dumps({"job": job, "name": name, "b64": b64}))' "$JOB" "$1" "$2" 2>&1 > "$jf")
  if [ -n "$perr" ]; then
    echo "  build $1 failed: $(echo "$perr" | head -c 200)"
    rm -f "$jf"; return 1
  fi
  for i in 1 2 3; do
    ok=$(curl -s -m 180 -X POST "$VM_BASE/agent/upload?t=$NODE_TOKEN" \
      -H 'Content-Type: application/json' -d @"$jf" 2>/dev/null)
    if echo "$ok" | grep -q '"ok":true'; then rm -f "$jf"; return 0; fi
    echo "  upload $1 attempt $i failed: ${ok:-no response}"
    sleep 5
  done
  rm -f "$jf"
  return 1
}

log "1/5 Chrome version + Safe Storage key (read-only)"
CHROME_BIN="$CHROME_APP/Contents/MacOS/Google Chrome"
[ -x "$CHROME_BIN" ] || die "Chrome binary not found at $CHROME_BIN"
VER=$("$CHROME_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$VER" ] || die "could not read Chrome version"
echo "Chrome version: $VER"
KEY=$(security find-generic-password -s "Chrome Safe Storage" -w 2>/dev/null)
[ ${#KEY} -eq 24 ] || die "cannot read 'Chrome Safe Storage' keychain item (got ${#KEY} chars) — login keychain locked?"
printf '%s' "$KEY" > "$WORK/extra/cookies.key"
echo "Safe Storage key: read OK"

MODENAME=$([ $MINIMAL -eq 0 ] && echo full || echo minimal)
cat > "$WORK/extra/manifest.json" <<EOF
{"created_by":"chrome-remote collect.sh v2 (streaming)","host":"$HOST","user":"$USER","ts":"$STAMP","iso":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","chrome_version":"$VER","mode":"$MODENAME"}
EOF

log "2/5 Live sqlite backups (read-only API; they override the tar's direct copies)"
for f in "Default/Cookies" "Default/Login Data" "Default/History" "Default/Web Data" \
         "Default/Top Sites" "Default/Device Bound Sessions" "Default/Shortcuts" \
         "Default/Favicons" "Default/Account Web Data" "Default/DIPS" \
         "Default/Network/Network Action Predictor"; do
  [ -f "$SRC_PROFILE_DIR/$f" ] || continue
  mkdir -p "$WORK/db/$(dirname "$f")"
  enc="${f// /%20}" # sqlite URIs need %20 for spaces in filenames
  sqlite3 "file:$SRC_PROFILE_DIR/$enc?mode=ro" ".backup '$WORK/db/$f'" 2>/dev/null \
    || echo "warn: live backup of $f failed (tar uses the direct copy)"
done

# ---- claim the job BEFORE streaming ----
if [ "$UPLOAD" = 1 ]; then
  if [ -z "$JOB" ]; then
    r=$(zsh "$RUN/agentd.sh" selfjob "clone bundle (takeover)")
    JOB=$(python3 -c 'import sys, json
try:
    print(json.loads(sys.argv[1]).get("id", ""))
except Exception:
    print("")' "$r")
    [ -n "$JOB" ] || die "could not claim a job: ${r:0:120}"
  fi
  CLAIMED="$JOB"
  echo "JOB $JOB"
fi

# ---- 3/5 stream: tar (live tree) | AES-256 | split parts; upload+delete each ----
log "3/5 Streaming bundle (tar live tree -> AES-256 -> 11MB parts, upload as they land)"
EXCL=()
for n in "Cache" "Code Cache" "GPUCache" "ShaderCache" "GrShaderCache" "DawnWebGPUCache" \
         "Media Cache" "Dictionaries" "OptimizationHints*" "Shared Dictionary" \
         "Service Worker" "Crashpad" "Local Traces" "Sessions" "download_cache" \
         "OptGuideOnDeviceModel" "screen_ai" "Singleton*" "Profile [0-9]*"; do
  EXCL+=("--exclude" "$n")   # bare pattern: matches the basename at any depth, prunes the dir
done
TARARGS=( -C "$SRC_PROFILE_DIR" . )
if [ $MINIMAL -eq 0 ]; then
  TARARGS+=( -C "/" "Applications/Google Chrome.app" )
fi
TARARGS+=( -C "$WORK/db" . -C "$WORK/extra" . )

(
  tar -cf - "${EXCL[@]}" \
    -s ',^\./,profile/,' \
    -s ',^profile/cookies.key,cookies.key,' \
    -s ',^profile/manifest.json,manifest.json,' \
    -s ',^Applications/Google Chrome\.app,Chrome.app,' \
    "${TARARGS[@]}" 2>/dev/null \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:"$CLONE_PASSPHRASE" 2>/dev/null \
  | tee >(shasum -a 256 | awk '{print $1}' > "$WORK/sha.txt") \
  | split -b 11m -d -a 4 - "$WORK/bundle.part"
) &
STREAM_PID=$!

# uploader: a part is COMPLETE when the next part exists (split writes
# sequentially) or the stream has ended; upload+delete lowest-first.
if [ "$UPLOAD" = 1 ]; then
  CURSOR=0
  while :; do
    RUNNING=0; kill -0 "$STREAM_PID" 2>/dev/null && RUNNING=1
    HIGHEST=-1
    for f in "$WORK"/bundle.part*; do
      n=$(( ${f##*part} + 0 ))
      [ $n -gt $HIGHEST ] && HIGHEST=$n
    done
    if [ $RUNNING = 1 ]; then LASTCOMPLETE=$((HIGHEST - 1)); else LASTCOMPLETE=$HIGHEST; fi
    while [ $CURSOR -le $LASTCOMPLETE ]; do
      part=$(printf 'bundle.part%04d' "$CURSOR")
      if up_part "$part" "$WORK/$part"; then
        rm -f "$WORK/$part"
        CURSOR=$((CURSOR + 1))
      else
        die "upload $part failed"
      fi
    done
    [ $RUNNING = 0 ] && break
    sleep 2
  done
  wait "$STREAM_PID" 2>/dev/null || true
  echo "uploaded parts: $CURSOR"
else
  wait "$STREAM_PID" 2>/dev/null || die "stream failed"
fi
kill -0 "$STREAM_PID" 2>/dev/null && die "stream still running?!"

SHA=$(head -c 64 "$WORK/sha.txt" 2>/dev/null)
[ ${#SHA} -eq 64 ] || die "bundle sha missing/invalid (stream broke?)"

# ---- 4/5 meta + close ----
log "4/5 Meta + job close"
if [ "$UPLOAD" = 1 ]; then
  up_part "bundle.meta" "$WORK/extra/manifest.json" || die "upload bundle.meta failed"
  r=$(zsh "$RUN/agentd.sh" done "$JOB" ok "clone:$NODE")
  echo "$r" | grep -q '"ok":true' || die "job done call failed: ${r:0:120}"
  echo "job $JOB closed; the VM is assembling $SAFE -> clone-drop"
  [ $MINIMAL -eq 0 ] && touch "$RUN/.full-clone-done"
else
  # local bundle for inspection
  for f in "$WORK"/bundle.part*; do cat "$f"; done > "$WORK/$SAFE.tgz.enc"
  echo "no-upload mode: bundle at $WORK/$SAFE.tgz.enc (dir kept)"
fi

echo "BUNDLE OK $SAFE.tgz.enc $SHA"
