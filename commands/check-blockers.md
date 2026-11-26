---
description: Recheck each Blocked item in this repo's status file and clear or move the ones that are no longer true
allowed-tools: Read, Edit, Write, Bash(*/bin/project-status* path), Bash(*/bin/project-status* lint *), Bash(*/bin/project-status* checked*), Bash(gh pr view *), Bash(gh issue view *), Bash(git fetch *), Bash(git branch *), Bash(git log *)
---

Recheck this repo's blockers now.

Status file: !`"${CLAUDE_PLUGIN_ROOT}/bin/project-status" path`

1. Follow the rules in `~/.project-status/_rules.md`, or `${CLAUDE_PLUGIN_ROOT}/RULES.md` if that file does not exist. Read them first if they are not already in context.
2. Re-read the status file from disk, then check every item under `## Blocked` against its source with the tools you have: a PR's state and reviews, a ticket's status, whether a branch has merged. Run the lookups in parallel.
3. For each item:
   - Resolved: remove it, and add any follow-up to `## Next`.
   - Waiting only on the user: move it to `## Next`.
   - Still waiting on someone else: keep it and its `(since ...)` date; if it names nothing checkable, add the PR, ticket, or branch you found.
   - Can't verify (no access, nothing to look up): keep it and say so in your reply.
4. If anything changed, update `## Last updated`, then run `"${CLAUDE_PLUGIN_ROOT}/bin/project-status" lint <status file>` and fix what it reports.
5. Run `"${CLAUDE_PLUGIN_ROOT}/bin/project-status" checked` to record the remaining blockers as checked today. Pass `--unverified "<text>"` for each one you could not verify, with its text as written before `(since ...)`.
6. Reply with one line per blocker: what you found and what you did.
