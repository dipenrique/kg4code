<!-- kg-kit:managed (kg-setup keeps this file up to date; delete this line to customise it) -->
# Knowledge graphs for coding agents

Two local graphs help coding agents (GitHub Copilot in VS Code, Copilot CLI and Claude Code) answer code questions without reading whole files:

| Graph | Storage | Best for | Interface |
| --- | --- | --- | --- |
| **code-review-graph (CRG)** | `.code-review-graph/graph.db` (SQLite, gitignored) | precise structure: definitions, callers/callees, imports, tests, blast radius, review context | MCP server `code-review-graph` (`.vscode/mcp.json`, `~/.copilot/mcp-config.json`) |
| **graphify** | `graphify-out/graph.json` + `GRAPH_REPORT.md` (gitignored) | concepts, communities, cross-file paths, "how does X relate to Y" | CLI: `graphify query`, `graphify path`, `graphify explain` |

This setup was installed by **kg-kit** (`kg-setup`). To re-run, upgrade or remove it, use `kg-setup install|doctor|uninstall`; see `kg-setup --help`.

## Lookup order

1. **CRG MCP tools** for structural questions:
   - `semantic_search_nodes_tool(query=X)`: where X is defined.
   - `query_graph_tool(pattern=callers_of|callees_of|imports_of|importers_of|tests_for|children_of|file_summary, target=X)`.
   - `get_impact_radius_tool(changed_files=[...])` before refactors.
   - `detect_changes_tool`, then `get_review_context_tool(changed_files=[...])` for reviews.
   - `get_affected_flows_tool`, `traverse_graph_tool`, `list_communities_tool` / `get_community_tool`, `list_graph_stats_tool`, `refactor_tool`.
   - When several repos are open at once, pass `repo_root=<absolute repo path>`.
2. **graphify CLI** when CRG misses, or for concepts and paths:
   - `graphify query "<question>" --graph <repo>/graphify-out/graph.json --budget 1500`
   - `graphify path "A" "B" --graph ...`
   - `graphify explain "<concept>" --graph ...`
3. **grep / read** for string literals, config values, `.md` / `.json` / `.yml`, logs, or once the graph has located the exact file and lines.

The graph can be stale or incomplete, so the source always wins. An empty result means "not indexed", not "does not exist".

## What runs automatically

Everything goes through one script, `.githooks/kg-hook.sh`, and its library `.githooks/kg-lib.sh`. Agent hooks always exit 0 and print `{}` on any problem, so they can never block the agent.

| Trigger | Configured in | Action | Cost on the critical path |
| --- | --- | --- | --- |
| Agent session start | `.github/hooks/code-review-graph.json` (`sessionStart`) | Injects a short status line for each open repo and a lookup cheatsheet. If a graph is stale, queues a background refresh. | ~0.5-1s |
| Before search/read tools | `.github/hooks/graphify.json` (`preToolUse`) | Runs `graphify hook-guard`, which adds a "try the graph first" nudge with matching nodes. Non-search tools exit on a fast path. | ~0.03s fast path, ~0.2s for searches |
| Agent turn end | `.github/hooks/code-review-graph.json` (`agentStop`) | If the working tree changed since the last CRG update, queues a detached `code-review-graph update --skip-flows`. | ~0.4s |
| `git commit` | `post-commit` git hook | graphify background rebuild, plus a detached CRG `update`. | ~0.4s |
| `git checkout` (branch switch) | `post-checkout` git hook | Same as commit. CRG does a full `build` for new or orphan branches, or when more than 200 files changed. | ~0.4s |
| `git merge` / `git pull` | `post-merge` git hook | Same as commit. | ~0.4s |
| `git rebase` / `commit --amend` | `post-rewrite` git hook | Same as commit. Runs once, after the rebase finishes. | ~0.4s |

Claude Code gets the same behaviour through the `hooks` in `.claude/settings.json`. VS Code is told not to load those (`chat.useClaudeHooks: false`) because it already runs the `.github/hooks` copies.

### Performance safeguards

- **Background work**: every rebuild runs detached under `nice` with a timeout. Git and the agent never wait for it.
- **Skips**: rebuilds are skipped when the machine is busy (summed CPU above `KG_MAX_CPU_PCT`, or free memory below `KG_MIN_FREE_MB`). The next commit or session retries.
- **One job at a time**: a per-repo lock prevents overlapping jobs, and stale locks expire after `KG_LOCK_STALE_MIN`.
- **Change detection**: a fingerprint (HEAD, diff checksum and untracked files) skips CRG updates when nothing changed.
- **Duplicate hooks**: hooks configured in several places fire for the same event. These duplicates are collapsed with an atomic per-payload marker.
- **No surprise first builds**: graphify only refreshes an existing graph and never starts a first build by itself. CRG only updates a repo that already has `.code-review-graph/`.
- **Linked worktrees** are skipped.

## Knobs (environment variables)

| Variable | Default | Effect |
| --- | --- | --- |
| `KG_HOOKS_DISABLE` | `0` | `1` disables every kg hook (agent and git). |
| `GRAPHIFY_SKIP_HOOK` | `0` | `1` skips only the graphify git rebuild. |
| `KG_NICE` | `10` | nice level for background jobs. |
| `KG_MAX_CPU_PCT` | `85` | macOS busy threshold (summed `ps %cpu` per core). |
| `KG_MAX_LOAD_RATIO` | `1.5` | Linux busy threshold (load average / cores). |
| `KG_MIN_FREE_MB` | `1536` | minimum free memory needed for a rebuild. |
| `KG_CRG_TIMEOUT` / `KG_GRAPHIFY_TIMEOUT` | `300` / `600` | job timeouts in seconds. |
| `KG_GRAPHIFY_WORKERS` | `2` | `GRAPHIFY_MAX_WORKERS` for git-triggered rebuilds. |
| `KG_CRG_FULL_THRESHOLD` | `200` | number of changed files on checkout above which CRG does a full build. |
| `KG_CRG_EMBED` | `auto` | runs `code-review-graph embed` after git-triggered updates only if `sentence_transformers` is installed. `0` disables it. |
| `KG_SESSION_GRAPHIFY_REFRESH` | `1` | `0` disables the session-start graphify refresh for stale graphs. |
| `KG_EXTRA_REPOS` | (empty) | extra repo paths (colon-separated) to include in session status and refresh. |
| `KG_CRG_BIN` / `KG_GRAPHIFY_BIN` | auto | override the tool binaries. |
| `KG_LOG_DIR` | `~/.cache/knowledge-graph-hooks` | location of `hooks.log` and `jobs.log`. |

## Manual commands

```sh
kg-setup doctor                                     # checks the whole setup for this repo
sh .githooks/kg-hook.sh status                      # both graphs: counts, freshness, tools, recent hook log
code-review-graph build --repo "$PWD"               # full CRG rebuild
code-review-graph update --repo "$PWD"              # incremental CRG update
graphify update .                                   # incremental graphify rebuild (code only)
tail -f ~/.cache/knowledge-graph-hooks/jobs.log     # background job output
tail -f ~/.cache/graphify-rebuild.log               # graphify git-hook rebuilds
```

## Troubleshooting

- **Hooks don't fire after editing hook JSON**: VS Code loads hooks when a chat session starts. Start a new chat session. Check the "GitHub Copilot Chat Hooks" output channel.
- **Nothing refreshes**: look in `~/.cache/knowledge-graph-hooks/hooks.log` for `skip:` lines (busy machine, lock held, unchanged fingerprint). Run `kg-setup doctor`.
- **MCP server missing**: check `code-review-graph --version`, then restart the server from the MCP view.
- **Re-installing graphify hooks**: run `kg-setup install` again. It re-runs `graphify hook install` and repairs the `# kg-*` blocks.
