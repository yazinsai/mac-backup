#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.backup}"
PLIST_PATH="$HOME/Library/LaunchAgents/com.macbackup.s3.plist"
CONFIG_JSON="$BACKUP_ROOT/config.json"

echo "==> mac-backup install"
echo "    backup root: $BACKUP_ROOT"

mkdir -p "$BACKUP_ROOT"/{bin,lib,logs,state}

if [[ ! -f "$CONFIG_JSON" ]]; then
  cp "$REPO_ROOT/config.json.example" "$CONFIG_JSON"
  echo "!! Created $CONFIG_JSON — edit s3_bucket and launchd_label before continuing."
  echo "   Re-run install.sh after editing."
  exit 1
fi

# Validate config parses
MAC_BACKUP_CONFIG="$CONFIG_JSON" python3 "$REPO_ROOT/src/config.py" s3_bucket >/dev/null

AWS_CLI="$(python3 -c "import json; print(json.load(open('$CONFIG_JSON')).get('aws_cli','/usr/local/bin/aws'))")"
if [[ "$AWS_CLI" == *YOUR* ]] || ! command -v "${AWS_CLI##*/}" >/dev/null 2>&1; then
  AWS_CLI="$(command -v aws || true)"
fi
if [[ -z "$AWS_CLI" ]]; then
  echo "!! aws CLI not found. Install AWS CLI v2 first."
  exit 1
fi

echo "==> compiling fsevents-changes"
clang -O2 -framework CoreServices -framework CoreFoundation \
  -o "$BACKUP_ROOT/bin/fsevents-changes" \
  "$REPO_ROOT/src/fsevents-changes.c"

echo "==> installing scripts"
install -m 755 "$REPO_ROOT/scripts/s3-backup.sh" "$BACKUP_ROOT/s3-backup.sh"
install -m 755 "$REPO_ROOT/src/fsevents_plan.py" "$BACKUP_ROOT/fsevents_plan.py"
install -m 755 "$REPO_ROOT/src/config.py" "$BACKUP_ROOT/lib/config.py"
install -m 755 "$REPO_ROOT/tools/purge-s3-junk.sh" "$BACKUP_ROOT/purge-s3-junk.sh"

LABEL=$(python3 -c "import json; print(json.load(open('$CONFIG_JSON'))['launchd_label'])")
PRIMARY=$(python3 -c "import json; print(json.load(open('$CONFIG_JSON'))['schedule']['primary_hour'])")
FALLBACK=$(python3 -c "import json; print(json.load(open('$CONFIG_JSON'))['schedule']['fallback_hour'])")

PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
sed \
  -e "s|@LAUNCHD_LABEL@|$LABEL|g" \
  -e "s|@BACKUP_ROOT@|$BACKUP_ROOT|g" \
  -e "s|@PRIMARY_HOUR@|$PRIMARY|g" \
  -e "s|@FALLBACK_HOUR@|$FALLBACK|g" \
  "$REPO_ROOT/launchd/com.macbackup.s3.plist.template" > "$PLIST_PATH"

echo "==> loading launchd agent ($LABEL)"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

# Seed FSEvents cursor if missing
if [[ ! -f "$BACKUP_ROOT/state/fsevents.json" ]]; then
  EID=$("$BACKUP_ROOT/bin/fsevents-changes" latest)
  MAC_BACKUP_CONFIG="$CONFIG_JSON" python3 "$BACKUP_ROOT/fsevents_plan.py" commit "$EID"
  echo "==> seeded FSEvents state (event_id=$EID)"
fi

echo ""
echo "Done. Test with:"
echo "  $BACKUP_ROOT/s3-backup.sh"
echo ""
echo "Optional — wake Mac before 3am backup:"
echo "  sudo pmset repeat wakeorpoweron MTWRFSU 03:00:00"
