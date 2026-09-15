"""Tests for bin/claude-acc-usage-update, run as a real subprocess against a
fake HOME/XDG_STATE_HOME/XDG_CACHE_HOME with stub `claude-acc` and
`omarchy-agent-usage-claude` binaries on PATH.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "bin" / "claude-acc-usage-update"
STUB_CLAUDE_ACC_SRC = Path(__file__).resolve().parent / "stub_claude_acc.py"
STUB_COLLECTOR_SRC = Path(__file__).resolve().parent / "stub_omarchy_agent_usage_claude.py"


def _install_stub(bin_dir: Path, name: str, source: Path) -> None:
    # Point the shebang straight at this interpreter instead of "env
    # python3": PATH-based resolution can hit a shim (e.g. mise) that
    # refuses to run under the fake HOME these tests use.
    text = source.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    assert lines[0].startswith("#!"), lines[0]
    lines[0] = f"#!{sys.executable}\n"
    dest = bin_dir / name
    dest.write_text("".join(lines), encoding="utf-8")
    dest.chmod(dest.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class UsageUpdateTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="claude-acc-usage-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

        self.home = self.tmp / "home"
        self.state_home = self.tmp / "state"
        self.cache_home = self.tmp / "cache"
        for d in (self.home, self.state_home, self.cache_home):
            d.mkdir(parents=True)

        self.stub_bin = self.tmp / "stubbin"
        self.stub_bin.mkdir()
        _install_stub(self.stub_bin, "claude-acc", STUB_CLAUDE_ACC_SRC)
        _install_stub(self.stub_bin, "omarchy-agent-usage-claude", STUB_COLLECTOR_SRC)

        self.stub_config_path = self.tmp / "stub-claude-acc.json"
        self.run_log_path = self.tmp / "run-log.jsonl"

        self.state_dir = self.state_home / "claude-acc-shell" / "usage"
        self.cache_root = self.cache_home / "claude-acc-shell" / "accounts"

    def write_stub_config(self, list_lines: list[str], active: str) -> None:
        self.stub_config_path.write_text(
            json.dumps({"list_lines": list_lines, "active": active}), encoding="utf-8"
        )

    def base_env(self, *, with_claude_acc: bool = True) -> dict:
        env = {
            "HOME": str(self.home),
            "XDG_STATE_HOME": str(self.state_home),
            "XDG_CACHE_HOME": str(self.cache_home),
            "STUB_CLAUDE_ACC_CONFIG": str(self.stub_config_path),
            "STUB_RUN_LOG": str(self.run_log_path),
            # Real PATH kept so the stubs' "#!/usr/bin/env python3" shebang
            # resolves; the stub dir is prepended so our fakes win.
            "PATH": str(self.stub_bin) + os.pathsep + os.environ.get("PATH", ""),
        }
        if not with_claude_acc:
            # An empty-but-real directory, not the system PATH: this
            # machine may have a real claude-acc installed for actual use
            # of the plugin, which would defeat "claude-acc is missing".
            empty_dir = self.tmp / "empty-path"
            empty_dir.mkdir(exist_ok=True)
            env["PATH"] = str(empty_dir)
        return env

    def run_script(self, args: list[str], env: dict | None = None, input_text: str | None = None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            env=env if env is not None else self.base_env(),
            capture_output=True,
            text=True,
            input=input_text if input_text is not None else "",
            timeout=15,
        )

    def make_account_dir(self, name: str) -> None:
        (self.home / ".claude-switch" / "accounts" / name).mkdir(parents=True, exist_ok=True)

    def make_default_dir(self) -> None:
        (self.home / ".claude").mkdir(parents=True, exist_ok=True)


class IngestionAllowlistTests(UsageUpdateTestCase):
    def test_valid_and_default_accounts_produce_records(self) -> None:
        self.make_default_dir()
        self.make_account_dir("acct1")
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com", "acct1 a1@example.com"],
            active="acct1",
        )

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state_dir / "default.json").is_file())
        self.assertTrue((self.state_dir / "acct1.json").is_file())

    def test_crafted_name_is_skipped_with_warning(self) -> None:
        self.make_default_dir()
        self.write_stub_config(
            list_lines=[
                "~/.claude/ default@example.com",
                "x;touch${IFS}pwned bad@example.com",
            ],
            active="default",
        )

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state_dir / "default.json").is_file())
        produced = {p.name for p in self.state_dir.glob("*.json")}
        self.assertEqual(produced, {"default.json"})
        self.assertIn("x;touch${IFS}pwned", result.stderr)
        # Nothing was ever executed with the crafted string as a shell command.
        self.assertFalse((self.tmp / "pwned").exists())

    def test_flag_like_name_is_skipped_with_warning(self) -> None:
        self.make_default_dir()
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com", "-h flag@example.com"],
            active="~/.claude/",
        )

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        produced = {p.name for p in self.state_dir.glob("*.json")}
        self.assertEqual(produced, {"default.json"})
        self.assertIn("-h", result.stderr)

    def test_literal_default_row_is_skipped_with_warning(self) -> None:
        self.make_default_dir()
        self.make_account_dir("default")
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com", "default other@example.com"],
            active="default",
        )

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        # Only one default.json, and it must be the real ~/.claude/ record,
        # not the colliding "default"-named row silently overwriting it.
        produced = {p.name for p in self.state_dir.glob("*.json")}
        self.assertEqual(produced, {"default.json"})
        record = json.loads((self.state_dir / "default.json").read_text())
        self.assertEqual(record["accountEmail"], "default@example.com")
        self.assertIn("default", result.stderr)

    def test_invalid_active_status_name_is_ignored(self) -> None:
        self.make_default_dir()
        self.make_account_dir("acct1")
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com", "acct1 a1@example.com"],
            active="x;touch${IFS}pwned",
        )

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads((self.state_dir / "default.json").read_text())
        self.assertFalse(record["active"])
        record1 = json.loads((self.state_dir / "acct1.json").read_text())
        self.assertFalse(record1["active"])
        self.assertFalse((self.tmp / "pwned").exists())

    def test_invalid_key_argument_is_skipped_with_warning(self) -> None:
        self.make_default_dir()
        self.make_account_dir("acct1")
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com", "acct1 a1@example.com"],
            active="acct1",
        )

        result = self.run_script(["x;touch${IFS}pwned"])

        self.assertEqual(result.returncode, 0, result.stderr)
        # An invalid key argument filters everything out (no valid key
        # matched it), so no accounts are updated on this run.
        self.assertIn("x;touch${IFS}pwned", result.stderr)
        self.assertFalse((self.tmp / "pwned").exists())
        self.assertFalse(self.state_dir.exists() and any(self.state_dir.glob("*.json")))


class LaunchModeTests(UsageUpdateTestCase):
    def test_launch_valid_key_execs_claude_acc_run(self) -> None:
        result = self.run_script(["--launch", "acct1"])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.run_log_path.is_file())
        logged = [json.loads(line) for line in self.run_log_path.read_text().splitlines()]
        self.assertEqual(logged, [["run", "--", "acct1"]])

    def test_launch_invalid_key_does_not_exec(self) -> None:
        result = self.run_script(["--launch", "x;touch${IFS}pwned"])

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.run_log_path.exists())
        self.assertFalse((self.tmp / "pwned").exists())

    def test_launch_flag_like_key_does_not_exec(self) -> None:
        result = self.run_script(["--launch", "-h"])

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.run_log_path.exists())

    def test_launch_missing_claude_acc_exits_nonzero(self) -> None:
        result = self.run_script(["--launch", "acct1"], env=self.base_env(with_claude_acc=False))

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.run_log_path.exists())
        self.assertIn("claude-acc", result.stderr.lower())


class SecureWriteTests(UsageUpdateTestCase):
    def test_records_are_written_atomically_with_safe_permissions(self) -> None:
        self.make_default_dir()
        self.make_account_dir("acct1")
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com", "acct1 a1@example.com"],
            active="acct1",
        )

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        state_mode = stat.S_IMODE(self.state_dir.stat().st_mode)
        self.assertEqual(state_mode, 0o700)

        record_path = self.state_dir / "acct1.json"
        self.assertTrue(record_path.is_file())
        record_mode = stat.S_IMODE(record_path.stat().st_mode)
        self.assertEqual(record_mode, 0o600)

        cache_dir = self.cache_root / "acct1"
        self.assertTrue(cache_dir.is_dir())
        cache_mode = stat.S_IMODE(cache_dir.stat().st_mode)
        self.assertEqual(cache_mode, 0o700)

        # No leftover fixed-name temp file from the write.
        self.assertFalse((self.state_dir / ".acct1.json.tmp").exists())

    def test_preplanted_symlink_at_fixed_tmp_path_is_untouched(self) -> None:
        self.make_default_dir()
        self.make_account_dir("acct1")
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com", "acct1 a1@example.com"],
            active="acct1",
        )

        self.state_dir.mkdir(parents=True, exist_ok=True)
        target = self.tmp / "attacker-target.txt"
        target.write_text("original", encoding="utf-8")
        symlink_path = self.state_dir / ".acct1.json.tmp"
        symlink_path.symlink_to(target)

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        # The write never followed the planted symlink: its target keeps
        # its original content no matter what became of the symlink itself
        # (prune_stale is allowed to reap it as a leftover .*.tmp file).
        self.assertEqual(target.read_text(encoding="utf-8"), "original")
        # The real record still landed at the normal path, as a regular file.
        record_path = self.state_dir / "acct1.json"
        self.assertTrue(record_path.is_file())
        self.assertFalse(record_path.is_symlink())
        record = json.loads(record_path.read_text())
        self.assertEqual(record["accountKey"], "acct1")

    def test_prune_stale_removes_stale_records_and_tmp_files(self) -> None:
        self.make_default_dir()
        self.write_stub_config(
            list_lines=["~/.claude/ default@example.com"],
            active="default",
        )

        self.state_dir.mkdir(parents=True, exist_ok=True)
        stale_record = self.state_dir / "gone.json"
        stale_record.write_text("{}", encoding="utf-8")
        stale_tmp = self.state_dir / ".gone.abc123.tmp"
        stale_tmp.write_text("{}", encoding="utf-8")

        result = self.run_script([])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale_record.exists())
        self.assertFalse(stale_tmp.exists())
        self.assertTrue((self.state_dir / "default.json").exists())


if __name__ == "__main__":
    unittest.main()
