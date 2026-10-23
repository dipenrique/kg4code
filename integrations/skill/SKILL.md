---
name: kg-setup
description: Set up, repair, upgrade, check or remove self-updating knowledge graphs (graphify + code-review-graph hooks, MCP server, agent instructions) in a repo or VS Code workspace. Use when the user asks to "set up knowledge graphs", "add graphify / code-review-graph", "inject the graph setup", "repair graph hooks", "kg-setup", or when graph hooks or the code-review-graph MCP server are missing or stale.
---

# kg-setup

`kg-setup` is an idempotent installer at `~/.local/bin/kg-setup` (the kit lives in `~/.local/share/kg-kit`). It wires graphify and code-review-graph auto-refresh for GitHub Copilot (VS Code and CLI) and Claude Code. Run it; never hand-edit the files it manages.

## Steps

1. **Pick targets.**
   - Use the git root of the current repo.
   - If the user works in a multi-root VS Code window, use the `*.code-workspace` file instead. Pass the workspace file so its settings are updated too.
   - You can pass several paths.
2. **Preview** with `kg-setup install --dry-run <targets>`, then summarise the planned changes in 3–6 bullets.
3. **Apply** with `kg-setup install --yes <targets>`.
   - The first run builds both graphs. On large repos this can take minutes.
   - It installs missing CLIs with `uv tool install` unless `--no-tools` is passed.
4. **Verify** with `kg-setup doctor <targets>`. Exit code 0 means healthy. Report any `FAIL` lines.
5. **Tell the user:**
   - start a new chat session, because hooks load at session start;
   - commit the tracked files shown by `git status` only if they want to (don't commit unless asked);
   - the backup and undo command printed in the summary (`kg-setup restore <dir>`).

## Other requests

| User wants | Command |
| --- | --- |
| check health / why are graphs stale | `kg-setup doctor <targets>`, then `sh .githooks/kg-hook.sh status` |
| upgrade after a kit update | `kg-setup self-update`, then `kg-setup install --yes <targets>` |
| remove the setup | `kg-setup uninstall --dry-run <targets>`, confirm with the user, then run it without `--dry-run`. Add `--purge` to delete graph data. |
| undo the last run | `kg-setup restore` lists backups; then `kg-setup restore <dir>` |
| Copilot only, leave `.claude/` alone | add `--no-claude` |
| skip the initial build | add `--no-build` |
| expose all CRG MCP tools | `KG_CRG_TOOLS=all kg-setup install --yes <targets>` |

If `kg-setup` is not on PATH, run `~/.local/share/kg-kit/bin/kg-setup self-install` first.

## What it changes (per repo)

- `.githooks/kg-lib.sh` and `kg-hook.sh`: the shared non-blocking runtime.
- The `post-commit`, `post-checkout`, `post-merge` and `post-rewrite` git hooks, plus `core.hooksPath=.githooks` if it is unset.
- `.github/hooks/code-review-graph.json` and `graphify.json`: Copilot agent hooks.
- `.claude/settings.json` hooks (when `.claude/` exists).
- `.vscode/mcp.json` (the `code-review-graph` server), and `.vscode/settings.json` / `*.code-workspace` (`chat.useClaudeHooks: false`).
- `.graphifyignore`, `.code-review-graphignore` and `.gitignore` marker blocks.
- `.github/instructions/code-review-graph.instructions.md` and `docs/agents/knowledge-graph.md`.
- User level: `~/.copilot/mcp-config.json` (`code-review-graph` server).

Each edit is a marker block or a file that kg-setup owns. Everything else in those files is preserved, and every touched file is backed up first.
