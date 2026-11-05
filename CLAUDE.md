# CLAUDE.md

Claude Code plugin that keeps `~/.project-status/<repo>.md` for every git repo, plus a dashboard. [README.md](README.md) covers behavior, scripts, and install.

## Commands

- `make check`: shellcheck, `claude plugin validate .`, and `tests/run.sh`. Run after any change.
- `make serve`: dashboard on localhost against live data.

## Constraints

- Portable: macOS bash 3.2 (no `mapfile`, associative arrays, or GNU-only flags; empty arrays under `set -u` are unbound) and BSD tools. Use `mtime` from `scripts/lib.sh`.
- Depend only on bash, git, jq, coreutils; the dashboard server is stdlib Python. jq 1.8 has no `--argfile`.
- Write only under `$HOME`.
- Assume no particular user, host, repo layout, or login. Remote Control is optional: API-key and gateway logins can't use it, so sessions must work with plain `claude --bg` and `claude attach`.
- Hooks exit 0 silently outside git repos and never modify an existing `<repo>.md`. `session-start.sh` truncates `additionalContext` at 9,500 chars (cap is 10,000).
- Stop uses `hookSpecificOutput.additionalContext`, not `decision: "block"`, which shows as a hook error.
- `install.sh` stays idempotent, backs up and merges `~/.claude/settings.json` (arrays unioned), and must work before or after a dotfiles merge. What it adds gets a `.added-<key>` marker so `uninstall.sh` removes only that. `_template.md` and `_rules.md` are copied once, then the user's.
- `--remote-control [name]` takes an optional value: pass a name before a positional prompt.
- Plugin names starting with `claude-` are reserved.
- The existing dashboard is the design reference; match its copy and spacing.
- Version tags are automatic on `main` from `plugin.json`'s `version`; bump it for a new major or minor.
