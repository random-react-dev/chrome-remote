#!/bin/zsh
# collect.sh — chrome-remote bundle collector (the "other PC").
#
# Packages the real Chrome's Default profile + Safe Storage key (+ optionally
# Chrome.app) into ONE encrypted bundle — the proven clone-sync method:
# rsync (caches excluded) + live read-only sqlite .backup + keychain read.
# Then uploads it to the VM agent API in 11MB parts as job uploads; the VM
# assembles the parts into ~/clone-drop when we report the job done with a
# "clone:" note, so Mac A's apply.sh can pick it up unchanged.
#
# Safe while the user's Chrome is running: everything is READ-only.
#
# Usage: collect.sh [--job <id>] [--minimal] [--no-upload]
#   --job <id>     use an existing job id (else claim one via selfjob)
#   --minimal      skip shipping Chrome.app (~1 GB smaller)
#   --no-upload    build the bundle locally only (dry runs / testing)
#
# Output contract (the last line is what other agents parse):
#   JOB <id>                   early, once a job is claimed
#   BUNDLE OK <name> <sha256>  success (bundle uploaded + job closed)
#   COLLECT FAIL <reason>      failure (job closed with status=fail if claimed)

set -uo pipefail
RUN="${CHROME_REMOTE_RUN:-$(cd "$(dirname "$0")" && pwd)}"
cd "$RUN"
# shellcheck disable=SC1091
source ./conf

JOB="" MINIMAL=0 UPLOAD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --job) JOB="${2:-}"; shift 2 ;;
    --minimal) MINIMAL=1; shift ;;
    --no-upload) UPLOAD=0; shift ;;
    *) echo "unknown flag: $1"; exit 2 ;;
  esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cr-collect.XXXXXX")
[ "$UPLOAD" = 1 ] && trap 'rm -rf "$WORK"' EXIT   # --no-upload keeps the bundle
mkdir -p "$WORK/staging"
log() { echo "==== $*"; }

STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$( (scutil --get LocalHostName 2>/dev/null || hostname) | tr -c 'A-Za-z0-9-_' '_' )
SAFE="clone-sync-${NODE//-/_}"
CLAIMED=""
die() { # <reason>
  echo "COLLECT FAIL $*"
  if [ $UPLOAD -eq 1 ] && [ -n "$CLAIMED" ]; then
    zsh "$RUN/agentd.sh" done "$CLAIMED" fail "$*" >/dev/null 2>&1 || true
  fi
  exit 1
}

# helper: upload one file to the current job (JSON via temp file — b64 is big)
up_part() { # <name> <file>
  local jf i ok
  jf=$(mktemp /tmp/.cr-part.XXXXXX)
  python3 -c 'import sys, json, base64
job, name, f = sys.argv[1], sys.argv[2], sys.argv[3]
b64 = base64.b64encode(open(f, "rb").read()).decode()
print(json.dumps({"job": job, "name": name, "b64": b64}))' "$JOB" "$1" "$2" > "$jf" 2>/dev/null || { rm -f "$jf"; return 1; }
  for i in 1 2 3; do
    ok=$(curl -s -m 180 -X POST "$VM_BASE/agent/upload?t=$NODE_TOKEN" \
      -H 'Content-Type: application/json' -d @"$jf" 2>/dev/null)
    rm -f "$jf"
    if echo "$ok" | grep -q '"ok":true'; then return 0; fi
    echo "  upload $1 attempt $i failed: ${ok:-no response}"
    sleep 5
  done
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
printf '%s' "$KEY" > "$WORK/staging/cookies.key"
echo "Safe Storage key: read OK"

log "2/5 Copying the Default profile (live RO read; caches excluded)"
rsync -a \
  --exclude 'Cache' --exclude 'Code Cache' --exclude 'GPUCache' --exclude 'ShaderCache' \
  --exclude 'GrShaderCache' --exclude 'DawnWebGPUCache' --exclude 'Media Cache' \
  --exclude 'Dictionaries' --exclude 'OptimizationHints*' --exclude 'Shared Dictionary' \
  --exclude 'Service Worker' --exclude 'Crashpad' --exclude 'Local Traces' --exclude 'Sessions' \
  --exclude 'OptGuideOnDeviceModel' --exclude 'screen_ai' --exclude 'Singleton*' \
  --exclude '/Profile [0-9]*' \
  "$SRC_PROFILE_DIR/." "$WORK/staging/profile/" || die "profile rsync"

# Re-copy the live SQLite DBs with the backup API (folds in the WAL while Chrome runs)
for f in "Default/Cookies" "Default/Login Data" "Default/History" "Default/Web Data" \
         "Default/Top Sites" "Default/Device Bound Sessions" "Default/Shortcuts" \
         "Default/Favicons" "Default/Account Web Data" "Default/DIPS" \
         "Default/Network/Network Action Predictor"; do
  [ -f "$SRC_PROFILE_DIR/$f" ] || continue
  enc="${f// /%20}" # sqlite URIs need %20 for spaces in filenames
  sqlite3 "file:$SRC_PROFILE_DIR/$enc?mode=ro" ".backup '$WORK/staging/profile/$f'" 2>/dev/null \
    || echo "warn: live backup of $f failed (using the rsynced copy)"
done

log "3/5 Chrome.app"
if [ $MINIMAL -eq 0 ]; then
  rsync -a "$CHROME_APP/." "$WORK/staging/Chrome.app/" || die "Chrome.app rsync"
else
  echo "minimal mode: Chrome.app not shipped"
fi

log "4/5 Manifest + package (tar.gz -> AES-256) + job claim"
MODENAME=$([ $MINIMAL -eq 0 ] && echo full || echo minimal)
cat > "$WORK/staging/manifest.json" <<EOF
{"created_by":"chrome-remote collect.sh v1","host":"$HOST","user":"$USER","ts":"$STAMP","iso":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","chrome_version":"$VER","mode":"$MODENAME"}
EOF
du -sh "$WORK/staging" 2>/dev/null | awk '{print "staging size:", $1}'
tar -czf "$WORK/$SAFE.tgz" -C "$WORK/staging" . || die "tar failed"
openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:"$CLONE_PASSPHRASE" \
  -in "$WORK/$SAFE.tgz" -out "$WORK/$SAFE.tgz.enc" || die "encryption failed"
SHA=$(shasum -a 256 "$WORK/$SAFE.tgz.enc" | awk '{print $1}')
ls -lh "$WORK/$SAFE.tgz.enc" | awk '{print "bundle:", $5, $9}'

if [ $UPLOAD -eq 1 ]; then
  if [ -z "$JOB" ]; then
    r=$(zsh "$RUN/agentd.sh" selfjob "clone bundle (bootstrap)")
    JOB=$(python3 -c 'import sys, json
try:
    print(json.loads(sys.argv[1]).get("id", ""))
except Exception:
    print("")' "$r")
    [ -n "$JOB" ] || die "could not claim a job: ${r:0:120}"
  fi
  CLAIMED="$JOB"
  echo "JOB $JOB"

  log "5/5 Uploading to $VM_BASE (11MB parts) as job $JOB"
  rm -f "$WORK/bundle.part"*
  split -b 11m -d -a 4 "$WORK/$SAFE.tgz.enc" "$WORK/bundle.part" || die "split failed"
  NPARTS=$(ls -1 "$WORK"/bundle.part* | wc -l | tr -d ' ')
  echo "parts: $NPARTS"
  up_part "bundle.meta" "$WORK/staging/manifest.json" || die "upload bundle.meta failed"
  for i in $(seq 0 $((NPARTS - 1))); do
    part=$(printf 'bundle.part%04d' "$i")
    up_part "$part" "$WORK/bundle.part$i" || die "upload $part failed"
    echo "uploaded $part"
  done
  r=$(zsh "$RUN/agentd.sh" done "$JOB" ok "clone:$NODE")
  echo "$r" | grep -q '"ok":true' || die "job done call failed: ${r:0:120}"
  echo "job $JOB closed; the VM is assembling $SAFE -> clone-drop"
else
  echo "no-upload mode: bundle left in $WORK (dir removed on exit; re-run with upload to ship)"
fi

echo "BUNDLE OK $SAFE.tgz.enc $SHA"
