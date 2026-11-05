# Project status rules

This repo has a status file that records what is in progress, what is next, and what is blocked. Its path and current contents are below.

- Read it at the start of the session to orient yourself. Re-read it from disk before editing; another session may have changed it.
- Before finishing any turn in which code changed, update it with the Edit or Write tool at the absolute path given.
- Also update it whenever the user mentions progress, a resolved or new blocker, or a change of plan, even if no code changed. Work done outside the repo (a router setting, a manual deploy) only reaches this file that way.
- If you commit during the turn, update it after the commit, not before. A later commit makes it stale again.
- Directly under the title, keep one plain line describing the project (for example "Personal knowledgebase"). If it is still the placeholder, fill it in during your first turn, even if no code changes.
- Keep exactly these sections:
  - `## Now`: 1-3 lines on what is actively in progress.
  - `## Next`: an ordered list of upcoming tasks.
  - `## Blocked`: anything waiting on a person, decision, or external system, each ending with `(since YYYY-MM-DD)`, or "None."
  - `## Last updated`: today's date (YYYY-MM-DD) and a one-line summary of what changed.
- Keep the whole file under 40 lines. Replace stale content; never append a log or history.
- Do not create a status file inside the repository. The file lives outside it so worktrees share one copy.
