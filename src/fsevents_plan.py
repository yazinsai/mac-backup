#!/usr/bin/env python3
"""Map FSEvents replay to backup sync targets."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# Allow running from repo checkout or installed ~/.backup layout.
_HERE = Path(__file__).resolve().parent
for _lib in (_HERE / "lib", _HERE):
    if (_lib / "config.py").exists():
        sys.path.insert(0, str(_lib))
        break

from config import load_config  # noqa: E402


def load_state(cfg: dict) -> dict:
    path = cfg["state_path"]
    if path.exists():
        return json.loads(path.read_text())
    return {"event_id": 0, "initialized": False}


def save_state(cfg: dict, event_id: int) -> None:
    path = cfg["state_path"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"event_id": event_id, "initialized": True}, indent=2) + "\n"
    )


def replay(cfg: dict, since_id: int) -> dict:
    paths = [str(p) for p in cfg["sync_roots"].values()]
    proc = subprocess.run(
        [str(cfg["fsevents_bin"]), str(since_id), *paths],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "fsevents-changes failed")
    return json.loads(proc.stdout)


def root_for_path(cfg: dict, path: str) -> str | None:
    p = Path(path)
    try:
        p = p.resolve()
    except OSError:
        pass

    for skip in cfg["fsevents_skip_paths"]:
        try:
            skip = Path(skip).resolve()
        except OSError:
            skip = Path(skip)
        if p == skip or skip in p.parents:
            return None

    for name, root in cfg["sync_roots"].items():
        try:
            root = Path(root).resolve()
        except OSError:
            root = Path(root)
        if p == root or root in p.parents:
            return name
    return None


def configured_targets(cfg: dict) -> tuple[list[str], list[str], str | None]:
    all_targets = list(cfg["sync_roots"].keys())
    projects_dir = cfg.get("projects_dir")
    personal = cfg.get("personal_dirs")

    if personal is None:
        personal_targets = [t for t in all_targets if t != projects_dir]
    else:
        personal_targets = [t for t in personal if t in cfg["sync_roots"]]

    return all_targets, personal_targets, projects_dir


def plan_sync_targets(cfg: dict, *, weekly_projects: bool) -> dict:
    state = load_state(cfg)
    since_id = int(state.get("event_id", 0))
    first_run = not state.get("initialized", False)
    all_targets, personal, projects_dir = configured_targets(cfg)

    if first_run or since_id == 0:
        targets = list(personal)
        if weekly_projects and projects_dir in cfg["sync_roots"]:
            targets.append(projects_dir)
        targets = [d for d in all_targets if d in targets]
        return {
            "first_run": True,
            "targets": targets,
            "new_event_id": None,
            "changed_paths": [],
            "dropped": False,
            "must_scan": False,
            "reason": "first_run",
        }

    ev = replay(cfg, since_id)
    new_event_id = int(ev["new_event_id"])
    dropped = bool(ev.get("dropped"))
    must_scan = bool(ev.get("must_scan"))
    changed_paths = ev.get("changed_paths", [])

    targets: set[str] = set()
    reasons: dict[str, str] = {}

    if dropped or must_scan:
        targets.update(personal)
        tag = "fsevents_dropped" if dropped else "fsevents_must_scan"
        for t in personal:
            reasons[t] = tag

    for path in changed_paths:
        root = root_for_path(cfg, path)
        if not root:
            continue
        if root == projects_dir and not weekly_projects:
            continue
        targets.add(root)
        reasons.setdefault(root, "fsevents_change")

    if weekly_projects and projects_dir in cfg["sync_roots"]:
        targets.add(projects_dir)
        reasons[projects_dir] = "weekly_sunday_3am"

    ordered = [d for d in all_targets if d in targets]

    return {
        "first_run": False,
        "targets": ordered,
        "new_event_id": new_event_id,
        "changed_paths": changed_paths[:50],
        "changed_path_count": len(changed_paths),
        "dropped": dropped,
        "must_scan": must_scan,
        "reasons": reasons,
    }


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: fsevents_plan.py plan|commit <event_id>", file=sys.stderr)
        return 2

    cfg = load_config()
    cmd = sys.argv[1]

    if cmd == "plan":
        weekly = os.environ.get("BACKUP_WEEKLY_PROJECTS", "0") == "1"
        print(json.dumps(plan_sync_targets(cfg, weekly_projects=weekly)))
        return 0

    if cmd == "commit":
        if len(sys.argv) != 3:
            print("usage: fsevents_plan.py commit <event_id>", file=sys.stderr)
            return 2
        save_state(cfg, int(sys.argv[2]))
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
