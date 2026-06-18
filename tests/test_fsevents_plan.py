import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from fsevents_plan import configured_targets, plan_sync_targets, root_for_path


class ConfiguredTargetsTest(unittest.TestCase):
    def test_first_run_uses_configured_root_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            cfg = {
                "sync_roots": {
                    "Work Docs": base / "work",
                    "clients/acme": base / "acme",
                    "Archive": base / "archive",
                },
                "personal_dirs": ["Work Docs"],
                "projects_dir": "clients/acme",
                "fsevents_skip_paths": [],
                "state_path": base / "state" / "fsevents.json",
            }

            self.assertEqual(configured_targets(cfg)[0], ["Work Docs", "clients/acme", "Archive"])
            self.assertEqual(plan_sync_targets(cfg, weekly_projects=False)["targets"], ["Work Docs"])
            self.assertEqual(
                plan_sync_targets(cfg, weekly_projects=True)["targets"],
                ["Work Docs", "clients/acme"],
            )

    def test_root_for_path_uses_configured_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            work = base / "custom work root"
            skip = work / "ignored"
            cfg = {
                "sync_roots": {"Work Docs": work},
                "fsevents_skip_paths": [skip],
            }

            self.assertEqual(root_for_path(cfg, str(work / "file.txt")), "Work Docs")
            self.assertIsNone(root_for_path(cfg, str(skip / "file.txt")))


if __name__ == "__main__":
    unittest.main()
