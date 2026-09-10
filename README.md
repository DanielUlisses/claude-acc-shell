# Claude Acc Usage

An [Omarchy](https://omarchy.org/) bar widget that shows Claude Code usage —
5-hour session and 7-day weekly rate limits, tokens by day, tokens by model —
for every account tracked by
[`claude-acc`](https://github.com/Nemo-Illusionist/claude-code-account-switcher),
one tab per account. Read-only, no switching; use `claude-acc` itself for
that (`claude-acc default`, `claude-acc link`, …), or right-click the bar
icon to open a terminal running `claude-acc run <account>`.

Styled after Omarchy's stock Agents panel — and built on top of it: the
numbers come from Omarchy's own `omarchy-agent-usage-claude` collector, run
once per claude-acc account. `claude-acc` itself is only used to discover
which accounts exist (`claude-acc list` / `claude-acc status`, both local,
no network) — the same local transcript scan and OAuth rate-limit probe the
stock Agents panel already does, so this widget adds no new way of talking
to Anthropic's API. Inspired by
[omaclaude-swap](https://github.com/Hylkw213/omaclaude-swap), which does the
account-switching side of this for `cswap`.

## Requirements

- Omarchy with the shell plugin system (`omarchy plugin` commands available)
  — specifically `omarchy-agent-usage-claude`, which ships with the stock
  Agents plugin
- [`claude-acc`](https://github.com/Nemo-Illusionist/claude-code-account-switcher)
  on `PATH` (or at `~/.claude-switch/bin/claude-acc`), with accounts under
  `~/.claude-switch/accounts/`
- `python3`

## Install

```bash
omarchy plugin add https://github.com/danielusilva/claude-acc-shell.git --enable
```

Lands in the bar's right section by default (next to the stock Agents icon).
This widget's per-account tabs already cover what the stock Agents panel
shows for the default Claude account, so consider disabling that one to
avoid seeing the same numbers twice:

```bash
omarchy plugin disable omarchy.agents
```

For local development, copy (not symlink — the plugin validator rejects
symlinks) this folder into `~/.config/omarchy/plugins/claude-acc.usage`, then
`omarchy plugin enable claude-acc.usage`. After changing the QML, run
`omarchy restart shell` — this widget's `Main.qml`/`Panel.qml` aren't always
picked up by the shell's own hot-reload.

## Interactions

- Bar icon: left = toggle panel, right = launch `claude-acc run` for the
  selected account, middle = next account.
- Panel: `h`/`l` switch account, `j`/`k` scroll, `r` or Enter refresh, Tab
  moves to the neighboring bar panel, Esc closes.
- IPC: `omarchy-shell claude-acc.usage <open|close|toggle|refresh|next>`.

## Data

Each account is one JSON record in
`~/.local/state/claude-acc-shell/usage/<key>.json`, written by
`bin/claude-acc-usage-update`. That script asks `claude-acc list`/`status`
for the account roster and which one is active, then runs
`omarchy-agent-usage-claude` once per account with `CLAUDE_CONFIG_DIR` set to
that account's directory (`~/.claude/` for the default account,
`~/.claude-switch/accounts/<name>/` for the rest). Each secondary account
gets its own `XDG_CACHE_HOME` so one account's rate-limit probe cache can't
collide with another's — the collector's limits cache isn't itself
namespaced by `CLAUDE_CONFIG_DIR`. The default account shares the real
`XDG_CACHE_HOME`, so it shares a cache with the stock Agents panel instead of
probing Anthropic's usage endpoint twice for the same account.

## Settings

`~/.config/omarchy/shell.json` → this widget's entry, or:

```bash
omarchy bar set claude-acc.usage refreshIntervalSec 900 --json
```

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often every account's usage is re-collected |
