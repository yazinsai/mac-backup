#!/bin/zsh
# Purge junk prefixes already uploaded to S3 (optional maintenance tool).
set -uo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.backup}"
CONFIG_PY="$BACKUP_ROOT/lib/config.py"
S3_BUCKET=$(python3 "$CONFIG_PY" s3_bucket | sed 's#^s3://##')
AWS=$(python3 "$CONFIG_PY" aws_cli)
LOG="$BACKUP_ROOT/logs/purge-$(date +%Y-%m-%d).log"

JUNK_PARTS=(
  "/build/" "/.build/" "/.archive/" "/.android-sdk/" "/DerivedData/"
  "/.beads/" "/node_modules/" "/.fcpcache/" "/dist/" "/Pods/"
  "/.gradle/" "/.pnpm-store/" "/__pycache__/" "/.next/" "/.turbo/"
  "/target/debug/" "/target/release/" "/venv/" "/.venv/" "/.gstack/"
  "/coverage/" "/.pytest_cache/"
)

purge_prefix() {
  echo "$(date): rm s3://${S3_BUCKET}/${1}" >> "$LOG"
  "$AWS" s3 rm "s3://${S3_BUCKET}/${1}" --recursive --only-show-errors >> "$LOG" 2>&1
}

echo "=== Purge started $(date) ===" >> "$LOG"

python3 - "$S3_BUCKET" "$AWS" "$LOG" <<'PY'
import json, subprocess, sys
bucket, aws, log = sys.argv[1:4]
junk = [
    "/build/", "/.build/", "/.archive/", "/.android-sdk/", "/DerivedData/",
    "/.beads/", "/node_modules/", "/.fcpcache/", "/dist/", "/Pods/",
    "/.gradle/", "/.pnpm-store/", "/__pycache__/", "/.next/", "/.turbo/",
    "/target/debug/", "/target/release/", "/venv/", "/.venv/", "/.gstack/",
    "/coverage/", "/.pytest_cache/",
]

def delete_batch(keys):
    if not keys:
        return 0
    payload = json.dumps({"Objects": [{"Key": k} for k in keys], "Quiet": True})
    subprocess.run([aws, "s3api", "delete-objects", "--bucket", bucket, "--delete", payload], check=True)
    return len(keys)

deleted = 0
batch = []
token = None
while True:
    cmd = [aws, "s3api", "list-objects-v2", "--bucket", bucket, "--prefix", "projects/", "--output", "json"]
    if token:
        cmd.extend(["--continuation-token", token])
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=open(log, "a"))
        sys.exit(result.returncode)
    data = json.loads(result.stdout or "{}")
    for obj in data.get("Contents", []):
        key = obj["Key"]
        if any(part in key for part in junk):
            batch.append(key)
            if len(batch) >= 1000:
                deleted += delete_batch(batch)
                batch = []
                print(f"deleted {deleted} junk objects...", flush=True)
    if not data.get("IsTruncated"):
        break
    token = data.get("NextContinuationToken")
deleted += delete_batch(batch)
print(f"projects junk delete complete: {deleted} objects")
PY

echo "=== Purge finished $(date) ===" >> "$LOG"
