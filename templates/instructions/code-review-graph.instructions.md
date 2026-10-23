---
applyTo: '**'
description: >-
  Route code questions through the code-review-graph MCP tools and the
  graphify CLI before grepping or reading whole files.
---

<!-- kg-kit:managed (kg-setup keeps this file up to date; delete this line to customise it) -->
<!-- code-review-graph MCP tools -->
## Knowledge graphs: code-review-graph + graphify

This repo (and any other repo open in the same workspace) has two auto-refreshed graphs. Use them to narrow scope before reading source. Full reference: `docs/agents/knowledge-graph.md`.

Lookup order for code questions:

1. **code-review-graph MCP tools** (structure). Pass `repo_root=<absolute repo path>` when more than one repo is open.
   - Where is X defined: `semantic_search_nodes_tool(query=X)`
   - Callers, callees, imports, tests: `query_graph_tool(pattern=callers_of|callees_of|imports_of|importers_of|tests_for|file_summary, target=X)`
   - Blast radius before a change: `get_impact_radius_tool(changed_files=[...])`, `get_affected_flows_tool`
   - Code review: `detect_changes_tool`, then `get_review_context_tool(changed_files=[...])`
   - Architecture: `list_communities_tool`, then `get_community_tool`. Renames and dead code: `refactor_tool`
2. **graphify CLI** (concepts, cross-file paths, or when CRG misses):
   - `graphify query "<question>" --graph <repo>/graphify-out/graph.json --budget 1500`
   - `graphify path "A" "B" --graph ...`
   - `graphify explain "<concept>" --graph ...`
3. **grep / read** for string literals, config, `.md`/`.json`/`.yml`, logs, or the exact lines the graph pointed to.

Verify in the source before changing behaviour. If the graph and the source disagree, trust the source. An empty result can mean "not indexed". Don't run graph builds yourself: hooks refresh both graphs in the background after each turn and after git commit, checkout, merge or rebase.
<!-- /code-review-graph MCP tools -->
