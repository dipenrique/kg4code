# kg-guard-start
# Knowledge-graph auto-refresh (graphify + code-review-graph) after git events.
# Every block is optional and silently no-ops when its tool or graph is absent;
# all rebuilds run detached, niced and resource-gated, so git returns at once.
# Disable: KG_HOOKS_DISABLE=1 (everything) or GRAPHIFY_SKIP_HOOK=1 (graphify only).
# Docs: docs/agents/knowledge-graph.md (managed by kg-setup; re-run it instead of editing)
KG_DIR="$(git rev-parse --show-toplevel 2>/dev/null)/.githooks"
if [ -f "$KG_DIR/kg-lib.sh" ]; then
  . "$KG_DIR/kg-lib.sh"
  kg_git_prelude
fi
# kg-guard-end
