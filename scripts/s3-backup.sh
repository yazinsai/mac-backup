#!/bin/zsh
# Daily personal backup + weekly projects sync to S3 Glacier Deep Archive.
# FSEvents decides which roots changed; aws s3 sync uploads deltas.
set -uo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.backup}"
CONFIG_PY="$BACKUP_ROOT/lib/config.py"
FSEVENTS_PLAN="$BACKUP_ROOT/fsevents_plan.py"
FSEVENTS_BIN="$BACKUP_ROOT/bin/fsevents-changes"
LOCKDIR="$BACKUP_ROOT/.lock"
LOCK_MAX_AGE=$((36 * 3600))
LOG_MAX_BYTES=$((10 * 1024 * 1024))
START_TIME=$(date +%s)

cfg() { python3 "$CONFIG_PY" "$@"; }

S3_BUCKET=$(cfg s3_bucket)
AWS=$(cfg aws_cli)
LOG="$BACKUP_ROOT/logs/backup-$(date +%Y-%m-%d).log"
PROJECTS_DIR=$(cfg projects_dir)
typeset -A SYNC_ROOTS
ALLOWED_TARGETS=()
while IFS=$'\t' read -r target source; do
  if [[ -n "$target" && -n "$source" ]]; then
    SYNC_ROOTS[$target]="$source"
    ALLOWED_TARGETS+=("$target")
  fi
done < <(cfg sync_roots_json | python3 -c 'import json,sys; roots=json.load(sys.stdin); [print(f"{name}\t{path}") for name, path in roots.items()]')

EXCLUDES=(
  --exclude "*/node_modules/*"
  --exclude "*/venv/*"
  --exclude "*/.venv/*"
  --exclude "*/.git/*"
  --exclude "*/__pycache__/*"
  --exclude "*/.next/*"
  --exclude "*/.turbo/*"
  --exclude "*/target/debug/*"
  --exclude "*/target/release/*"
  --exclude "*/dist/*"
  --exclude "*/build/*"
  --exclude "*/.build/*"
  --exclude "*/.archive/*"
  --exclude "*/.android-sdk/*"
  --exclude "*/DerivedData/*"
  --exclude "*/Pods/*"
  --exclude "*/.gradle/*"
  --exclude "*/.pnpm-store/*"
  --exclude "*/.fcpcache/*"
  --exclude "*/.beads/*"
  --exclude "*/.gstack/*"
  --exclude "*/coverage/*"
  --exclude "*/.pytest_cache/*"
  --exclude "*/.mypy_cache/*"
  --exclude "*/.ruff_cache/*"
  --exclude "*/Render Files/*"
  --exclude "*.tsbuildinfo"
  --exclude "*.log"
  --exclude "*.db-wal"
  --exclude "*.db-shm"
  --exclude "*.DS_Store"
)

if [ -d "$LOCKDIR" ]; then
  lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
  lock_mtime=$(stat -f %m "$LOCKDIR/pid" 2>/dev/null || echo 0)
  lock_age=$(($(date +%s) - lock_mtime))
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null && [ "$lock_age" -lt "$LOCK_MAX_AGE" ]; then
    echo "$(date): backup already running (pid $lock_pid), skipping" >> "$LOG"
    exit 0
  fi
  echo "$(date): breaking stale lock (pid=${lock_pid:-?}, age=${lock_age}s)" >> "$LOG"
  rm -rf "$LOCKDIR"
fi
mkdir "$LOCKDIR" || exit 1
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

sync_dir() {
  local d=$1
  local partial=$2
  local rc=0
  local source=""
  local extra=()

  if [[ -z "$d" || "$d" == /* || "$d" == *..* ]]; then
    echo "ERROR: refusing unsafe sync target: ${d:-<empty>}" >> "$partial"
    return 1
  fi
  if (( ! ${ALLOWED_TARGETS[(Ie)$d]} )); then
    echo "ERROR: refusing unconfigured sync target: $d" >> "$partial"
    return 1
  fi
  source="${SYNC_ROOTS[$d]}"
  if [[ -z "$source" || ! -d "$source" ]]; then
    echo "ERROR: refusing missing configured source for $d: ${source:-<empty>}" >> "$partial"
    return 1
  fi

  while IFS= read -r ex; do
    [[ -n "$ex" ]] && extra+=(--exclude "$ex")
  done < <(cfg sync_excludes_json "$d" | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)]')

  echo "--- Syncing $d from $source ---" >> "$partial"
  "$AWS" s3 sync "$source" "$S3_BUCKET/$d" \
    --storage-class DEEP_ARCHIVE \
    --no-follow-symlinks \
    "${EXCLUDES[@]}" \
    "${extra[@]}" \
    --only-show-errors \
    --no-progress >> "$partial" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && rc=0
  echo "--- Finished $d exit=$rc ---" >> "$partial"
  return "$rc"
}

should_sync_projects() {
  [ "$(date +%w)" -eq 0 ] && [ "$(date +%H)" -eq 3 ]
}

commit_fsevents() {
  python3 "$FSEVENTS_PLAN" commit "$1" >> "$LOG" 2>&1
}

echo "=== Backup started $(date) ===" >> "$LOG"
sync_rc=0
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/s3backup.XXXXXX")
trap 'rm -rf "$LOCKDIR" "$tmpdir"' EXIT INT TERM

if [ ! -x "$FSEVENTS_BIN" ]; then
  echo "ERROR: missing $FSEVENTS_BIN — run install.sh" >> "$LOG"
  exit 1
fi

weekly_projects=0
should_sync_projects && weekly_projects=1

plan_json=$(BACKUP_WEEKLY_PROJECTS="$weekly_projects" python3 "$FSEVENTS_PLAN" plan 2>>"$LOG") || {
  echo "ERROR: fsevents plan failed" >> "$LOG"
  exit 1
}

echo "--- FSEvents plan: $plan_json ---" >> "$LOG"

targets=()
while IFS= read -r target; do
  [[ -n "$target" ]] && targets+=("$target")
done < <(python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(d.get("targets",[])))' <<< "$plan_json")
new_event_id=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("new_event_id") or "")' <<< "$plan_json")
first_run=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print("1" if d.get("first_run") else "0")' <<< "$plan_json")

if [ ${#targets[@]} -eq 0 ]; then
  echo "--- FSEvents: no changes, skipping sync ---" >> "$LOG"
  [ -n "$new_event_id" ] && commit_fsevents "$new_event_id"
  echo "=== Backup finished $(date) exit=0 (no changes) ===" >> "$LOG"
  exit 0
fi

pids=()
partials=()
for (( i = 1; i <= ${#targets[@]}; i++ )); do
  d="${targets[$i]}"
  partial="$tmpdir/target-$i.log"
  partials+=("$partial")
  ( sync_dir "$d" "$partial" ) &
  pids+=($!)
done

for pid in $pids; do
  wait "$pid" || sync_rc=$?
done

for partial in "${partials[@]}"; do
  [ -f "$partial" ] && cat "$partial" >> "$LOG"
done

if [ "$sync_rc" -eq 0 ]; then
  [ "$first_run" = "1" ] && new_event_id=$("$FSEVENTS_BIN" latest)
  if [ -n "$new_event_id" ]; then
    commit_fsevents "$new_event_id"
    echo "--- FSEvents committed event_id=$new_event_id ---" >> "$LOG"
  fi
fi

echo "=== Backup finished $(date) exit=$sync_rc ===" >> "$LOG"

if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt "$LOG_MAX_BYTES" ]; then
  gzip -kf "$LOG"
fi

ls -t "$BACKUP_ROOT/logs"/backup-*.log "$BACKUP_ROOT/logs"/backup-*.log.gz 2>/dev/null \
  | tail -n +13 | xargs rm -f 2>/dev/null

duration=$(( $(date +%s) - START_TIME ))
duration_human="${duration}s"
[ "$duration" -ge 3600 ] && duration_human="$((duration / 3600))h $(( (duration % 3600) / 60 ))m"
[ "$duration" -ge 60 ] && [ "$duration" -lt 3600 ] && duration_human="$((duration / 60))m $((duration % 60))s"

if [ "$sync_rc" -ne 0 ]; then
  failures=$(grep -c 'upload failed' "$LOG" 2>/dev/null || echo "?")
  osascript -e "display notification \"Exit $sync_rc after $duration_human, $failures failed uploads. $LOG\" with title \"Mac Backup failed\" sound name \"Basso\"" 2>/dev/null
fi

exit $sync_rc
