# mac-backup

Incremental Mac → S3 Glacier Deep Archive backup using **FSEvents** (only sync changed folders) and **aws s3 sync** (only upload changed files).

Designed for developer machines: aggressive excludes for `node_modules`, build artifacts, Apple photo library churn, etc.

## How it works

```
launchd (3am + 12pm fallback)
    └── s3-backup.sh
            ├── fsevents_plan.py   → which roots changed since last run?
            ├── fsevents-changes   → native FSEvents replay (C)
            └── aws s3 sync          → upload deltas to S3 Deep Archive
```

| Schedule | What syncs |
|----------|------------|
| Daily (if FSEvents sees changes) | `Documents`, `Desktop`†, `Pictures` |
| Sunday 3am only | `~/projects` |
| No changes | skip entirely (~seconds) |

† `Desktop/local/*` is excluded from **new** uploads but existing S3 copies are kept (no `--delete`).

## Repo layout

```
mac-backup/
├── README.md
├── install.sh                 # deploy to ~/.backup + load launchd
├── config.json.example        # copy → ~/.backup/config.json
├── scripts/
│   └── s3-backup.sh           # main backup entrypoint
├── src/
│   ├── fsevents-changes.c     # FSEvents replay binary (compiled on install)
│   ├── fsevents_plan.py       # maps FS events → sync targets
│   └── config.py              # shared config loader
├── launchd/
│   └── com.macbackup.s3.plist.template
└── tools/
    └── purge-s3-junk.sh       # optional: delete build junk already in S3
```

Runtime state lives in `~/.backup/` (not in git): logs, FSEvents cursor, lock files.

## New machine setup

### 1. Prerequisites

- macOS with Xcode Command Line Tools (`xcode-select --install`)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- `python3` (macOS system Python is fine)
- `gh` + git (to clone this repo)

### 2. Create S3 bucket + IAM user

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${ACCOUNT_ID}-mac-backup"

aws s3 mb "s3://${BUCKET}" --region us-east-1
```

Create an IAM user (e.g. `mac-backer-upper`) with this policy (replace bucket name):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME/*"
    }
  ]
}
```

Configure credentials:

```bash
aws configure
# Access key, secret, region (e.g. us-east-1), json output
```

### 3. Clone and configure

```bash
git clone git@github.com:yazinsai/mac-backup.git
cd mac-backup

cp config.json.example ~/.backup/config.json   # install.sh also does this on first run
```

Edit `~/.backup/config.json`:

- `s3_bucket` → `s3://YOUR-ACCOUNT-ID-mac-backup`
- `launchd_label` → unique reverse-DNS label, e.g. `com.yourname.mac-backup`
- Adjust `sync_roots` to define the exact local roots that are allowed to sync

### 4. Install

```bash
chmod +x install.sh
./install.sh
```

This will:

- compile `fsevents-changes` into `~/.backup/bin/`
- copy scripts into `~/.backup/`
- install + load the launchd agent
- seed the FSEvents cursor (avoids re-uploading everything on first incremental run)

### 5. Wake schedule (recommended)

`launchd` won't fire at 3am if the Mac is asleep:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 03:00:00
```

### 6. Test

```bash
~/.backup/s3-backup.sh
tail -f ~/.backup/logs/backup-$(date +%Y-%m-%d).log
```

Touch a file in `Documents/`, run again — should sync only `Documents`.

## Operations

| Task | Command |
|------|---------|
| Manual backup | `~/.backup/s3-backup.sh` |
| View today's log | `tail -f ~/.backup/logs/backup-$(date +%Y-%m-%d).log` |
| Check launchd status | `launchctl list \| grep mac-backup` |
| Reload after config change | `./install.sh` |
| FSEvents plan (dry) | `python3 ~/.backup/fsevents_plan.py plan` |
| Purge S3 build junk | `~/.backup/purge-s3-junk.sh` |

Logs notify via macOS notification **on failure only**.

## Config reference

See `config.json.example`. Key fields:

| Field | Purpose |
|-------|---------|
| `s3_bucket` | Destination `s3://...` URI |
| `sync_roots` | Allowed sync roots, mapped from S3 prefix name to local path |
| `personal_dirs` | Daily incremental root names; must be keys in `sync_roots` |
| `sync_excludes` | Per-root AWS sync exclude patterns, keyed by `sync_roots` name |
| `fsevents_skip_paths` | FS paths that should not trigger a sync |
| `schedule.primary_hour` | Main run (default 3) |
| `schedule.fallback_hour` | Second chance if asleep (default 12) |

## Cost notes

- Storage class is **S3 Glacier Deep Archive** (~$0.00099/GB/mo)
- Deep Archive has a **180-day minimum** per object version — avoid backing up churning files (logs, WALs, build dirs)
- FSEvents skip + excludes exist specifically to reduce storage and sync time

## Upgrading

```bash
cd mac-backup && git pull
./install.sh
```

## Migrating an existing `~/.backup` install

If you already have a working `~/.backup` from manual setup:

1. Create `~/.backup/config.json` from `config.json.example` with your bucket + label
2. Run `./install.sh` — overwrites scripts but preserves `state/` and `logs/`
3. Update launchd label in config if changing from a previous plist

## License

Private / personal use.
