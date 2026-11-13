---
description: Record progress, a decision, or a cleared blocker in this repo's status file now
argument-hint: "[what changed]"
allowed-tools: Read, Edit, Write, Bash(*/bin/project-status path), Bash(*/bin/project-status lint *)
---

Update this repo's project status file now.

Status file: !`"${CLAUDE_PLUGIN_ROOT}/bin/project-status" path`

What changed, from the user: $ARGUMENTS

1. Follow the rules in `~/.project-status/_rules.md`, or `${CLAUDE_PLUGIN_ROOT}/RULES.md` if that file does not exist. Read them first if they are not already in context.
2. Re-read the status file from disk; another session may have changed it.
3. Fold in what the user said above plus anything this session established: progress, new or cleared blockers, plan changes. Replace stale content instead of appending.
4. Run `"${CLAUDE_PLUGIN_ROOT}/bin/project-status" lint <status file>` and fix everything it reports, until it prints nothing.
