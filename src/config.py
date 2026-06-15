#!/usr/bin/env python3
"""Shared config loader for mac-backup."""
from __future__ import annotations

import json
import os
from pathlib import Path

HOME = Path.home()


def expand(path: str) -> Path:
    return Path(os.path.expanduser(path)).resolve()


def config_path() -> Path:
    env = os.environ.get("MAC_BACKUP_CONFIG")
    if env:
        return Path(env).expanduser()
    return HOME / ".backup" / "config.json"


def load_config() -> dict:
    path = config_path()
    if not path.exists():
        raise FileNotFoundError(f"missing config: {path}")
    cfg = json.loads(path.read_text())
    backup_root = expand(cfg.get("backup_root", "~/.backup"))
    sync_roots = {
        name: expand(p) for name, p in cfg.get("sync_roots", {}).items()
    }
    skip_paths = [expand(p) for p in cfg.get("fsevents_skip_paths", [])]
    return {
        **cfg,
        "backup_root": backup_root,
        "sync_roots": sync_roots,
        "fsevents_skip_paths": skip_paths,
        "state_path": backup_root / "state" / "fsevents.json",
        "fsevents_bin": backup_root / "bin" / "fsevents-changes",
        "fsevents_plan": backup_root / "fsevents_plan.py",
        "logs_dir": backup_root / "logs",
    }


if __name__ == "__main__":
    import sys

    cfg = load_config()
    key = sys.argv[1] if len(sys.argv) > 1 else None
    if key == "s3_bucket":
        print(cfg["s3_bucket"])
    elif key == "aws_cli":
        print(cfg.get("aws_cli", "/usr/local/bin/aws"))
    elif key == "backup_root":
        print(cfg["backup_root"])
    elif key == "projects_dir":
        print(cfg.get("projects_dir", "projects"))
    elif key == "desktop_excludes_json":
        print(json.dumps(cfg.get("desktop_sync_excludes", [])))
    else:
        print(json.dumps(cfg, default=str))
