#!/usr/bin/env python3
"""Stub `omarchy-agent-usage-claude`: always reports a minimal valid record,
regardless of which account's CLAUDE_CONFIG_DIR it was pointed at.
"""
import json

print(json.dumps({"ready": True, "limits": []}))
