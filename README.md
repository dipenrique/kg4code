# kg-kit

Self-updating knowledge graphs for coding agents, in one command. The kit wires
[graphify](https://pypi.org/project/graphifyy/) (concept graph) and
[code-review-graph](https://pypi.org/project/code-review-graph/) (structural graph) into any git repo or VS Code workspace.
It does the same for every repo in a multi-root workspace. Both graphs refresh themselves:

- **Git hooks** (post-commit, post-checkout, post-merge, post-rewrite) run detached and resource-gated, so git returns at once.
- **Copilot agent hooks** (`.github/hooks/*.json`) rebuild at session start and agent stop. A pre-tool guard nudges the agent to query the graph before it greps.
- **Claude Code hooks** (`.claude/settings.json`) are optional and route through the same `kg-hook.sh`.
- **MCP**: `.vscode/mcp.json` (per repo) and `~/.copilot/mcp-config.json` (Copilot CLI) serve code-review-graph with a curated tool list.
- **Instructions + docs**: `.github/instructions/code-review-graph.instructions.md` routes agents to the graphs. `docs/agents/knowledge-graph.md` explains the setup.

## One-time install (per machine)

```sh
git clone <this-repo> ~/.local/share/kg-kit     # or copy the folder there
~/.local/share/kg-kit/bin/kg-setup self-install
```

`self-install` does five things:

- links `~/.local/bin/kg-setup`
- installs graphify and code-review-graph if they are missing (uv, then pipx, then `pip --user`)
- adds the **`kg-setup` skill** (`~/.copilot/skills`; pass `--claude` for `~/.claude/skills` too)
- adds the **`/kg-setup` prompt** (VS Code user prompts)
- adds three **user tasks** (VS Code `tasks.json`)

## Set up a project: pick any one

| How | What to do |
| --- | --- |
| One click (VS Code) | Command Palette → *Tasks: Run Task* → **Knowledge graphs: set up / repair this workspace** |
| Chat | Type `/kg-setup` in Copilot Chat (or ask “set up knowledge graphs here”; the skill triggers) |
| Terminal | `kg-setup` in the repo, or `kg-setup path/to/app.code-workspace` for every folder of a workspace |
| Preview first | `kg-setup --dry-run …` or the *preview setup (dry run)* task |

Then start a new chat session, because hooks load at session start. Commit the files that `git status` shows.

## Commands

```text
kg-setup [install] [paths…]   set up / repair (default; idempotent, safe to re-run)
kg-setup doctor   [paths…]    verify everything + graph freshness (exit 1 on problems)
kg-setup uninstall [paths…]   remove the kit's blocks/files (--purge also deletes graph data)
kg-setup restore  [backup]    undo a run from its backup (no arg: list recent backups)
kg-setup self-install         (re)install CLI link, skill, prompt, VS Code tasks
kg-setup self-update          git pull the kit, then self-install
```

Paths can be repo dirs or `*.code-workspace` files; the default is the current directory. A `*.code-workspace` file inside a given dir is picked up automatically (`--no-workspace` to skip).

Flags: `-n/--dry-run`, `-y/--yes`, `-f/--force` (replace customised docs), `--no-build`, `--no-claude` / `--claude`, `--no-mcp`, `--no-user`, `--no-tools`, `--purge`.

Env: `KG_CRG_TOOLS` (comma-separated MCP tools, or `all`), `KG_KIT_BACKUP_DIR`.

## Safety model

- **Idempotent**: every edit is a marker-delimited block (`# kg-guard-*`, `# kg-crg-*`, `# kg-setup-*`, `# kg-gitignore-*`), a JSON merge (jq) or a managed file (`<!-- kg-kit:managed -->`). Re-running converges, and a second run reports *Everything already up to date*.
- **Backups**: every write is backed up first to `~/.cache/kg-kit/backups/<timestamp>/` and recorded, along with `core.hooksPath` changes, in `manifest.txt`. `kg-setup restore <timestamp>` reverts the run exactly.
- **Respects existing setup**:
  - Existing `.git/hooks/*` are carried over into `.githooks/` and keep running.
  - A global `core.hooksPath` (or husky) is detected and never overridden.
  - Non-graph Claude hooks (e.g. agentmemory) are kept even when they share a matcher group.
  - JSONC files keep their comments.
  - Docs you customised are left alone: remove the managed-marker line to opt out, or pass `--force` to replace them.
- **Uninstall** strips only kit-owned blocks and files. It deletes files left empty or holding only kit defaults, unsets `core.hooksPath` only if the kit set it, and drops carried-over hook copies.

## Updating the setup everywhere

1. Edit the templates in `templates/`, or the logic in `bin/kg-setup`, and bump `VERSION`.
2. Run `bash tests/roundtrip.sh`. It installs, re-runs, runs doctor, commits, uninstalls and restores on a throwaway two-repo fixture.
3. Commit the kit, then run `kg-setup` (or the VS Code task) in each project; doctor flags stale scripts.

## Layout

```text
bin/kg-setup                  the installer (bash 3.2+, needs git, jq, perl, awk)
templates/githooks/           kg-lib.sh, kg-hook.sh (runtime), prelude + crg hook blocks
templates/github-hooks/       Copilot agent hook JSONs
templates/claude/hooks.json   Claude Code hook entries
templates/ignore/             default ignores, .graphifyignore/.code-review-graphignore block, .gitignore block
templates/instructions/       Copilot instructions file
templates/docs/               docs/agents/knowledge-graph.md
integrations/skill/           kg-setup skill
integrations/vscode/          /kg-setup prompt + user tasks
tests/                        fixture builder + round-trip test
```
