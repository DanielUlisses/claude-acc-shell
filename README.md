# Claude Acc Usage

An [Omarchy](https://omarchy.org/) bar widget that shows Claude Code
rate-limit usage (5-hour session and 7-day weekly windows) for every account
tracked by [`claude-acc`](https://github.com/danielusilva/claude-acc-shell) —
read-only, no switching. For switching accounts, use `claude-acc` itself
(`claude-acc default`, `claude-acc link`, …).

Inspired by [omaclaude-swap](https://github.com/Hylkw213/omaclaude-swap),
which does the same thing for `cswap`.

## Requirements

- Omarchy with the shell plugin system (`omarchy plugin` commands available)
- [`claude-acc`](https://github.com/danielusilva/claude-acc-shell) on `PATH`
  (or at `~/.claude-switch/bin/claude-acc`) — this widget shells out to
  `claude-acc usage` and `claude-acc status`, and has nothing to show
  without it
- `python3` (used by `bin/claude-acc-roster` to reshape `claude-acc`'s
  text output into JSON — `claude-acc usage` has no `--json` flag)

## Install

```bash
omarchy plugin add <git-url-of-this-repo> --enable
```

For local development, copy (not symlink — the plugin validator rejects
symlinks) this folder into `~/.config/omarchy/plugins/claude-acc.usage`,
then `omarchy plugin enable claude-acc.usage`.

## Interactions

- Bar icon: left/right = toggle panel, middle = refresh.
- Panel: `j`/`k` scroll, `r` or Enter refresh, Tab moves to the neighboring
  bar panel, Esc closes.
- IPC: `omarchy-shell claude-acc.usage <open|close|toggle|refresh>`.

## Settings

`~/.config/omarchy/shell.json` → this widget's entry, or:

```bash
omarchy bar set claude-acc.usage refreshIntervalSec 300 --json
```

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `300` | How often `claude-acc usage` is re-run |
