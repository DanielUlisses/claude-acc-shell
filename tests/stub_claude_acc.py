#!/usr/bin/env python3
"""Stub `claude-acc` used by tests: serves `list`/`status` from a fixture
JSON file (STUB_CLAUDE_ACC_CONFIG) and records `run` argv to a log file
(STUB_RUN_LOG) instead of actually launching anything.
"""
import json
import os
import sys


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("usage: claude-acc <command>", file=sys.stderr)
        return 2

    config_path = os.environ.get("STUB_CLAUDE_ACC_CONFIG")
    config = {}
    if config_path and os.path.isfile(config_path):
        with open(config_path, encoding="utf-8") as f:
            config = json.load(f)

    command = args[0]
    if command == "list":
        for line in config.get("list_lines", []):
            print(line)
        return 0

    if command == "status":
        print("Active account: " + config.get("active", "default"))
        return 0

    if command == "run":
        log_path = os.environ.get("STUB_RUN_LOG")
        if log_path:
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(args) + "\n")
        return 0

    print(f"claude-acc: unknown command {command!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
