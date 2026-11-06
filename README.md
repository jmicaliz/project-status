# project-status

A Claude Code plugin that gives every git repo you work in a status file recording what's in progress, what's next, and what's blocked. The file is created automatically and Claude keeps it current.

Status files live centrally at `~/.project-status/<repo>.md`, not inside each repo. Agent View background sessions run in `.claude/worktrees/<id>/`, so an in-repo file would fork per worktree. `<repo>` is derived from git's common dir, so a worktree and its main checkout share one file.

## How it works

- **SessionStart hook**: records the repo's path in `~/.project-status/.repos/<repo>` for the dashboard, creates `~/.project-status/<repo>.md` from `~/.project-status/_template.md` if it's missing, then injects the file's path, its contents, and the maintenance rules from `~/.project-status/_rules.md` into context. Runs on startup, resume, clear, compact, and fork. Your `~/.claude/CLAUDE.md` is never touched.
- **Stop hook**: if the newest change in the working tree (latest commit time, or mtime of any modified or untracked file) is newer than the status file, it tells Claude to update the file before finishing. It does nothing when `stop_hook_active` is set, so it fires at most once per turn.
- Directories that aren't git repos are ignored silently.

## Requirements

`bash`, `git`, `jq`, coreutils, and the `claude` CLI. The dashboard server also needs `python3` (standard library only). Works on Linux and macOS (bash 3.2, BSD tools), and on systems with a read-only root such as SteamOS (writes only under `$HOME`). Remote Control is optional, so API-key and gateway logins work too.

Install jq if needed:

- macOS: `brew install jq`
- Debian/Ubuntu: `sudo apt install jq`
- SteamOS: install via Homebrew or Nix in `$HOME` (the root filesystem is read-only)

## Install

```sh
git clone <this repo> ~/repos/project-status
~/repos/project-status/install.sh
```

`install.sh` is idempotent. It:

1. Backs up `~/.claude/settings.json` to `~/.claude/backups/` (creating the settings file if it doesn't exist).
2. Merges into `permissions` (never overwrites; arrays are unioned):
   - `additionalDirectories`: `$HOME/.project-status`
   - `allow`: `Edit(/$HOME/.project-status/**)`, so sessions in `default` and `dontAsk` modes can edit status files without prompting
3. Sets `statusLine` to `scripts/statusline.sh` if you have none. An existing status line is kept, and install prints the command that wraps it so the dashboard still gets usage. See [Usage](#usage).
4. Creates `~/.project-status/` and copies [template.md](template.md) and [RULES.md](RULES.md) to `_template.md` and `_rules.md` if you don't have them yet. Existing `<repo>.md` files are never touched.
5. Links the `project-status` CLI into `~/.local/bin` unless something is already there, and prints the line to add if `~/.local/bin` isn't on your `PATH`. See [CLI](#cli).
6. Registers this repo as a local marketplace and installs the `project-status@project-status` plugin at user scope.

The plugin loads in place from the repo, so edits here take effect at the next session or after `/reload-plugins`.

It coexists with a dotfiles bootstrap that jq deep-merges `settings.json` (arrays unioned), in either run order.

## Uninstall

```sh
~/repos/project-status/uninstall.sh
```

It removes the plugin, the marketplace, the CLI link, the permission entries and status line that install added (markers in `~/.project-status/.added-*` track which ones; a status line you've since changed is left alone), `_template.md` and `_rules.md` unless you've customized them, the recorded repo paths in `.repos/`, the usage records in `.usage/`, and the dashboard token. Your status files are kept. The dashboard units are separate: `make dashboard-uninstall`. `~/.project-status/` is removed only if it's empty.

## Customize

- **Template**: edit your copy at `~/.project-status/_template.md`. New status files are created from it; `{{REPO}}` is replaced with the repo name. Install never overwrites it, so delete it and re-run `install.sh` to get the default back.
- **Rules**: edit your copy at `~/.project-status/_rules.md`. Changes apply at the next session start. Like the template, install never overwrites it.
- **Status directory (tests only)**: the hooks honor `PROJECT_STATUS_DIR`.

## CLI

`project-status` reads the same data as the dashboard, generated fresh on each run, so it works without the dashboard services.

```sh
project-status ls                     # repos that need you first: live sessions by state, stale or blocked status, Now
project-status ls --all               # include repos idle for 14 days
project-status ls --json              # the full status.json payload
project-status needs                  # only what's waiting on you; exits 1 when nothing is
project-status attach [repo]          # attach to the repo's most urgent background session, or start a new one
project-status attach repo id         # attach to that session, or resume it if it has ended (an id prefix works)
project-status start [repo] [prompt]  # start a background session in a fresh worktree, like the dashboard's Start
project-status start --next 2         # use item 2 of the repo's Next list as the prompt; --attach jumps in
project-status show [repo]            # print the status file
project-status edit [repo]            # open it in $VISUAL or $EDITOR
project-status rm <id> [-y]           # remove a background session; asks first unless -y
```

The repo defaults to the one you are in. `attach` runs the same commands as the dashboard's Jump in, adding `--remote-control` when the machine supports it. A session running in someone's terminal can't be attached, so `attach` says so and prints its Remote Control link if it has one. `needs -q` prints nothing, so `project-status needs -q && notify-send "Claude needs you"` works from cron or a shell prompt. The link points into the clone, so moving the clone breaks it until you re-run `install.sh`.

## Dashboard

A single static page (`dashboard/`) that answers "what needs me right now?" and "where did I leave off?" for every project, on laptop and phone.

- `scripts/generate-status.sh` writes `dashboard/status.json`. It parses every `~/.project-status/<repo>.md`, marks a project stale using the same check as the Stop hook, and joins live sessions from `claude agents --json --all`, matched to repos through git's common dir so worktree sessions land on the right project. Repos with sessions but no status file yet are listed too.
- The page (`index.html`, `app.js`, `styles.css`, self-hosted Inter and Phosphor icons) fetches `status.json` every 30 s, keeps the last good copy in `localStorage`, and shows an offline banner when the fetch fails or the data is more than four intervals old.
- **Jump in** copies a command: `claude attach <id>` for background sessions, `claude --resume <id>` for closed ones, and `claude` in the repo for a new session. `--remote-control` is added when the machine supports it. Viewed from another device, the command is wrapped in `ssh <host> -t`; on `localhost` it runs as is. Interactive sessions running in someone's terminal can't be attached, so they show "in a terminal" instead.
- **Open in Claude** appears for any session with Remote Control on (its link comes from `~/.claude/sessions/<pid>.json`) and for always-on `claude remote-control` servers (from `bridge-pointer.json`).
- **Start** (on each Next item) and **New session** start a background session without a terminal. `scripts/dashboard-server.py` serves the page and runs `scripts/start-session.sh <repo> [prompt]`, which runs `claude --bg` in the repo's recorded path, in a fresh `ps-<timestamp>` worktree, with Remote Control when the machine supports it. The buttons only appear when the page is served by that server.

### Starting sessions

- **Token**: the server creates `~/.project-status/.token` (mode 600). The dashboard asks for it once per browser; print it with `make token`. Requests without it, or from another origin, are refused.
- **Repos**: only names recorded in `~/.project-status/.repos/` can be started, so the browser never sends a path. The repo must be trusted for background sessions: run `claude` in it once and accept the prompt.
- **Remote Control is optional**. It's skipped automatically when Claude Code uses an API key, `apiKeyHelper`, Bedrock, Vertex, Foundry, or an `ANTHROPIC_BASE_URL` gateway, or sets `disableRemoteControl` (checked in the environment and the `env` blocks of `~/.claude/settings.json` and `settings.local.json`). Sessions still start and can be attached with `claude attach <id>`. Force it with `PROJECT_STATUS_REMOTE_CONTROL=on|off`.
- `PROJECT_STATUS_WORKTREE=0` starts sessions in the main checkout instead of a worktree.
- **Remove** (trash icon, then confirm) on background sessions runs `scripts/remove-session.sh <id>`: `claude rm`, which stops the session and deletes it and its worktree. A worktree with uncommitted changes is kept, and the notice says where it is. Only ids that `claude agents` lists as background sessions are accepted.

Run it:

```sh
make serve                # http://localhost:8765, regenerates every 30 s, Ctrl+C to stop
make token                # print the start token the page asks for
make dashboard-install    # systemd user units (Linux) or launchd agents (macOS): 30 s refresh + server on localhost:8765
make dashboard-install-lan  # same, but serves 0.0.0.0:8765 so other devices on your network can reach it
make dashboard-uninstall
```

`dashboard-install` serves only this machine; reach it from elsewhere over an SSH tunnel or a VPN. `dashboard-install-lan` serves over plain HTTP to your network, where anyone who has the token can start sessions as you. Over plain HTTP from another host the Clipboard API is unavailable, so copying falls back to `execCommand`. On Linux, user services stop at logout unless lingering is on (`loginctl enable-linger`). The web service must not kill its child processes when it stops (`KillMode=process` on systemd, `AbandonProcessGroup` on launchd) because the `claude --bg` daemon it may fork hosts every background session on the machine. On macOS, logs go to `~/Library/Logs/project-status-*.log`.

**Behind Cloudflare Access**: `dashboard-server.py --access` requires a valid Access JWT (`Cf-Access-Jwt-Assertion`) on every request, page and API alike, on top of the start token. It reads `PROJECT_STATUS_ACCESS_TEAM_DOMAIN` (e.g. `myteam.cloudflareaccess.com`) and `PROJECT_STATUS_ACCESS_AUD` (the Access application's AUD tag) and refuses to start without both, so a deleted or misbound Access policy fails closed. `scripts/access.py` verifies RS256 against the team's published keys with the standard library alone. Run it as a separate instance from any LAN listener, since LAN browsers can't present a JWT.

### Usage

The **Usage** section, below Projects, shows plan limits and what each listed session has used.

- **Plan limits** (5-hour, weekly, and a gateway spend limit when one applies) reach scripts only through Claude Code's status line input, so `install.sh` sets `scripts/statusline.sh` as your status line. To keep your own, set `statusLine.command` to `scripts/statusline.sh <your command>`: it records usage and then prints your command's output instead of its own. Alone, it prints e.g. `5h 24% · 7d 41% · $1.84` and saves the limits to `~/.project-status/.usage/limits.json` and each session's cost to `.usage/sessions/<id>.json`. Limits refresh whenever an interactive session gets a reply; the section shows when they were recorded. API-key logins have no plan limits, so the meters are replaced by a note.
- **Tokens** come from each session's transcript (`~/.claude/projects/<dir>/<id>.jsonl`), counted once per API message. Input includes cache reads and writes. Results are cached in `.usage/tokens/` by file size and mtime, so a 100 MB transcript is read once.
- **Cost** is Claude Code's own client-side estimate at list price, and only exists for sessions that ran the status line. Background sessions may show "—".
- `.usage/` files untouched for 30 days are pruned.

Generator settings: `PROJECT_STATUS_ROOTS` (default `~/repos ~/code`) is where repos are looked up when the SessionStart hook hasn't recorded their path yet; `PROJECT_STATUS_INTERVAL` sets the advertised refresh interval.

## Make targets

Run `make` to list them. The main ones are `install`, `uninstall`, `test`, `validate`, `lint`, and `check` (all three). `status-init`, `status-path`, and `status` create, locate, and show this repo's own status file. `dashboard`, `serve`, `dashboard-install`, `dashboard-install-lan`, and `dashboard-uninstall` are covered above.

## Tests

```sh
tests/run.sh
```

Pipes sample hook input into each script against throwaway repos and checks: missing, fresh, and stale status files; a custom `_rules.md`; `stop_hook_active`; modified, untracked, deleted, and committed changes; worktrees; non-git directories; and context truncation. It also runs the dashboard generator against a fixture session list and checks parsing, session-to-repo matching (including worktrees), titles, Remote Control links, and stale detection; checks the status line, including wrapping another one; runs `start-session.sh` and the CLI against a fake `claude`; and runs the dashboard server to check the token, origin, error handling, and `--access` refusals. `tests/test_access.py` checks the JWT verifier against a throwaway RSA key.

## Known limitations

- Two repos with the same directory name in different paths share one `<repo>.md`.
- In a git submodule, the common dir is `<super>/.git/modules/<name>`, so the status file is named `modules.md`.
