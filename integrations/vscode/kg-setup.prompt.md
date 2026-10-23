---
description: 'Set up, repair or check self-updating knowledge graphs (graphify + code-review-graph) for this workspace'
agent: 'agent'
---

Set up knowledge graphs for the repos in this workspace with **kg-setup** (kit: `~/.local/share/kg-kit`).

1. Collect the workspace targets:
   - The git repo root of every workspace folder.
   - If this is a multi-root window, the `*.code-workspace` file path. Pass the workspace file, not the folders, so its settings are updated too.
2. Preview: run `~/.local/bin/kg-setup install --dry-run <targets>` and summarise what would change.
3. Apply: run `~/.local/bin/kg-setup install --yes <targets>`. If the user asked only to check, run `kg-setup doctor <targets>` instead and stop.
4. Verify: run `~/.local/bin/kg-setup doctor <targets>` and report the result in a few lines.
5. Tell the user to:
   - start a **new chat session**, because hooks load at session start;
   - review and commit the tracked files listed by `git status`;
   - undo if needed with `kg-setup restore <backup dir>` (the path is printed in the summary).

Rules:

- Don't edit hook, MCP or ignore files by hand. Re-run kg-setup instead, because it is idempotent.
- Don't commit or push unless the user asks.
- If `~/.local/bin/kg-setup` is missing, run `~/.local/share/kg-kit/bin/kg-setup self-install` first.

${input:extra:Optional: extra flags (e.g. --no-claude, --no-build) or paths}
