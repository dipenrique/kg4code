#!/bin/sh
# kg-hook.sh — entry point for knowledge-graph hooks (graphify + code-review-graph).
#
# Agent hooks (GitHub Copilot in VS Code and Copilot CLI, wired in .github/hooks/*.json).
# They read the event JSON on stdin, always exit 0 and print exactly one JSON object:
#   kg-hook.sh session-start      graph status + query cheatsheet; stale graphs refresh in background
#   kg-hook.sh agent-stop         once per agent turn: background incremental CRG update of changed repos
#   kg-hook.sh guard search|read  graph-first nudge via `graphify hook-guard` (fast path + de-duplicated)
#
# Internal / manual:
#   kg-hook.sh crg-run <repo> <update|update-fast|build> <reason>   runs detached (spawned by the lib)
#   kg-hook.sh graphify-run <repo> <reason>                         runs detached (spawned by the lib)
#   kg-hook.sh status                                               human-readable graph/lock/log status
#
# Docs: docs/agents/knowledge-graph.md

KG_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
# shellcheck source=kg-lib.sh
if [ ! -f "$KG_DIR/kg-lib.sh" ] || ! . "$KG_DIR/kg-lib.sh"; then
  case "${1:-}" in session-start|agent-stop|guard) echo '{}' ;; esac
  exit 0
fi

# ------------------------------------------------------------ session-start --
session_start() {
  _in="$1"
  kg_prune_tmp
  if kg_disabled || ! kg_once session "$_in"; then echo '{}'; return 0; fi
  _repos=$(kg_repos "$_in")
  _lines=""
  _have=0
  _nl='
'
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    _crg_part=""; _gfy_part=""
    _head=$(git -C "$_r" rev-parse HEAD 2>/dev/null)
    _br=$(git -C "$_r" branch --show-current 2>/dev/null)
    if [ -f "$_r/.code-review-graph/graph.db" ]; then
      _have=1
      _st="fresh"
      if [ "$(kg_crg_head_sha "$_r")" != "$_head" ] || kg_crg_changed "$_r"; then
        _st="stale"
        kg_crg_queue "$_r" update-fast session-start && _st="stale, refreshing in background"
      fi
      _crg_part="CRG $(kg_crg_counts "$_r") ($_st)"
    elif [ -d "$_r/.code-review-graph" ]; then
      _crg_part="CRG not built (run: code-review-graph build)"
    fi
    if [ -f "$_r/graphify-out/graph.json" ]; then
      _have=1
      _built=$(kg_graphify_built_commit "$_r")
      _st="fresh"
      case "$_head" in
        "$_built"*) [ -n "$_built" ] || _st="unknown" ;;
        *)
          _st="stale"
          if [ "$KG_SESSION_GRAPHIFY_REFRESH" = "1" ] && kg_graphify_queue "$_r" session-start; then
            _st="stale, refreshing in background"
          fi
          ;;
      esac
      _gfy_part="graphify $(kg_graphify_summary "$_r") ($_st)"
    fi
    [ -n "$_crg_part$_gfy_part" ] || continue
    _lines="$_lines- $(basename "$_r") [$_br@$(printf '%.7s' "$_head")] $_r: $_crg_part${_crg_part:+${_gfy_part:+ | }}$_gfy_part$_nl"
  done <<EOF
$_repos
EOF
  if [ "$_have" != "1" ]; then echo '{}'; return 0; fi

  _text="KNOWLEDGE GRAPHS (auto-refreshed by hooks; reference: docs/agents/knowledge-graph.md)
${_lines}Lookup order for code questions: CRG MCP tools -> graphify CLI -> grep/read.
  where is X defined     semantic_search_nodes_tool(query=X)
  who calls/imports X    query_graph_tool(pattern=callers_of|callees_of|importers_of|tests_for, target=X)
  blast radius           get_impact_radius_tool(changed_files=[...])
  review a diff          detect_changes_tool, then get_review_context_tool(changed_files=[...])
  architecture           list_communities_tool -> get_community_tool
  CRG miss / explore     graphify query \"<question>\" --graph <repo>/graphify-out/graph.json --budget 1500
  path A -> B            graphify path \"A\" \"B\" --graph <repo>/graphify-out/graph.json
Several repos: pass repo_root=<repo path above> to CRG tools.
Use grep/read directly for string literals, config values, .md/.json/.yml and logs."
  _esc=$(printf '%s' "$_text" | kg_json_escape)
  case "$_in" in
    *'"hook_event_name"'*) printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$_esc" ;;
    *) printf '{"additionalContext":"%s"}\n' "$_esc" ;;
  esac
}

# --------------------------------------------------------------- agent-stop --
agent_stop() {
  _in="$1"
  if ! kg_disabled && kg_once stop "$_in"; then
    kg_repos "$_in" | while IFS= read -r _r; do
      [ -d "$_r/.code-review-graph" ] || continue
      kg_crg_changed "$_r" || continue
      kg_crg_queue "$_r" update-fast agent-stop
    done
  fi
  echo '{}'
}

# -------------------------------------------------------------------- guard --
guard() {
  _kind="$1"; _in="$2"
  _gfy=$(kg_bin graphify) || { echo '{}'; return 0; }
  kg_disabled && { echo '{}'; return 0; }
  _tn=$(kg_json_get tool_name "$_in")
  [ -n "$_tn" ] || _tn=$(kg_json_get toolName "$_in")
  # Fast path: only search / read style tool calls reach graphify (python start-up).
  case "$_kind" in
    search)
      case "$_tn" in
        run_in_terminal|bash|Bash|shell)
          case "$_in" in
            *grep*|*' rg '*|*'"rg '*|*ripgrep*|*'find '*|*' ag '*|*'"ag '*|*' ack '*|*'"ack '*|*' fd '*|*'"fd '*) ;;
            *) echo '{}'; return 0 ;;
          esac ;;
        grep_search|grep|Grep|rg) ;;
        *) echo '{}'; return 0 ;;
      esac ;;
    read)
      case "$_tn" in read_file|view|Read|file_search|glob|Glob) ;; *) echo '{}'; return 0 ;; esac ;;
    *) echo '{}'; return 0 ;;
  esac
  kg_once "guard-$_kind" "$_in" || { echo '{}'; return 0; }
  # Map VS Code / Copilot tool argument names onto the shape graphify expects.
  _norm=$(printf '%s' "$_in" | sed -e 's/"toolArgs"[[:space:]]*:/"tool_input":/' -e 's/"filePath"[[:space:]]*:/"file_path":/g')
  case "$_tn" in
    grep_search|file_search) _norm=$(printf '%s' "$_norm" | sed -e 's/"query"[[:space:]]*:/"pattern":/') ;;
  esac
  _dir=""
  if [ "$_kind" = "read" ]; then
    _fp=$(kg_json_get file_path "$_norm")
    [ -n "$_fp" ] || _fp=$(kg_json_get path "$_norm")
    case "$_fp" in /*) _dir=$(kg_toplevel "$(dirname "$_fp")") ;; esac
  fi
  [ -n "$_dir" ] || _dir=$(kg_toplevel "$(kg_json_get cwd "$_in")")
  [ -n "$_dir" ] || _dir="$PWD"
  _out=$(cd "$_dir" 2>/dev/null && export CLAUDE_PROJECT_DIR="$_dir" \
    && printf '%s' "$_norm" | kg_with_timeout 4 "$_gfy" hook-guard "$_kind" 2>/dev/null)
  case "$_out" in
    '{'*) printf '%s\n' "$_out" ;;
    *) echo '{}' ;;
  esac
}

# ------------------------------------------------------------ background jobs --
crg_embed() {
  case "$KG_CRG_EMBED" in 0|false|no|off) return 0 ;; esac
  if [ "$KG_CRG_EMBED" = "auto" ]; then
    _py=$(head -n 1 "$1" 2>/dev/null | sed 's/^#![[:space:]]*//')
    case "$_py" in */env\ *) _py=${_py#*/env } ;; esac
    [ -n "$_py" ] || return 0
    # shellcheck disable=SC2086
    $_py -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('sentence_transformers') else 1)" \
      2>/dev/null || return 0
  fi
  kg_with_timeout "$KG_CRG_TIMEOUT" "$1" embed --repo "$2"
  kg_log "crg embed rc=$? $2"
}

crg_run() {
  _r="$1"; _mode="${2:-update}"; _why="${3:-manual}"
  _crg=$(kg_bin code-review-graph) || exit 0
  [ -d "$_r/.code-review-graph" ] || exit 0
  _ld=$(kg_lockdir crg "$_r")
  kg_lock_acquire "$_ld" || exit 0
  trap 'rm -rf "$_ld"' EXIT
  trap 'exit 1' HUP INT TERM
  _fp=$(kg_crg_fingerprint "$_r")
  _t0=$(date +%s)
  case "$_mode" in
    build)       kg_with_timeout "$KG_CRG_TIMEOUT" "$_crg" build --repo "$_r" -q ;;
    update-fast) kg_with_timeout "$KG_CRG_TIMEOUT" "$_crg" update --skip-flows --repo "$_r" -q ;;
    *)           kg_with_timeout "$KG_CRG_TIMEOUT" "$_crg" update --repo "$_r" -q ;;
  esac
  _rc=$?
  [ "$_rc" -eq 0 ] && printf '%s\n' "$_fp" > "$_r/.code-review-graph/.kg-fingerprint" 2>/dev/null
  kg_log "crg $_mode rc=$_rc $(( $(date +%s) - _t0 ))s ($_why) $_r"
  case "$_why" in post-*) [ "$_rc" -eq 0 ] && crg_embed "$_crg" "$_r" ;; esac
  exit 0
}

graphify_run() {
  _r="$1"; _why="${2:-manual}"
  _g=$(kg_bin graphify) || exit 0
  [ -f "$_r/graphify-out/graph.json" ] || exit 0
  _ld=$(kg_lockdir graphify "$_r")
  kg_lock_acquire "$_ld" || exit 0
  trap 'rm -rf "$_ld"' EXIT
  trap 'exit 1' HUP INT TERM
  cd "$_r" || exit 0
  export GRAPHIFY_MAX_WORKERS="${GRAPHIFY_MAX_WORKERS:-$KG_GRAPHIFY_WORKERS}"
  export PYTHONHASHSEED=0
  _t0=$(date +%s)
  kg_with_timeout "$KG_GRAPHIFY_TIMEOUT" "$_g" update .
  kg_log "graphify update rc=$? $(( $(date +%s) - _t0 ))s ($_why) $_r"
  exit 0
}

# ------------------------------------------------------------------- status --
status() {
  kg_repos "{\"cwd\":\"$PWD\"}" | while IFS= read -r _r; do
    _head=$(git -C "$_r" rev-parse HEAD 2>/dev/null)
    echo "== $_r  (HEAD $(printf '%.12s' "$_head"))"
    if [ -f "$_r/.code-review-graph/graph.db" ]; then
      _sha=$(kg_crg_head_sha "$_r")
      _c="fresh"; { [ "$_sha" != "$_head" ] || kg_crg_changed "$_r"; } && _c="stale"
      echo "   code-review-graph: $(kg_crg_counts "$_r"), built at $(printf '%.12s' "$_sha"), $_c$(kg_lock_busy "$(kg_lockdir crg "$_r")" && echo ', update running')"
    else
      echo "   code-review-graph: not built"
    fi
    if [ -f "$_r/graphify-out/graph.json" ]; then
      echo "   graphify: $(kg_graphify_summary "$_r"), built from $(kg_graphify_built_commit "$_r")$(kg_lock_busy "$(kg_lockdir graphify "$_r")" && echo ', refresh running')"
    else
      echo "   graphify: not built"
    fi
  done
  echo "== tools: code-review-graph=$(kg_bin code-review-graph || echo missing) graphify=$(kg_bin graphify || echo missing)"
  if kg_resources_ok; then echo "== resources: ok"; else echo "== resources: busy (background rebuilds would be skipped)"; fi
  echo "== recent log ($KG_LOG_DIR/hooks.log)"
  tail -n 12 "$KG_LOG_DIR/hooks.log" 2>/dev/null | sed 's/^/   /'
}

# ----------------------------------------------------------------- dispatch --
case "${1:-}" in
  session-start) session_start "$(cat 2>/dev/null)" ;;
  agent-stop)    agent_stop "$(cat 2>/dev/null)" ;;
  guard)         guard "${2:-}" "$(cat 2>/dev/null)" ;;
  crg-run)       shift; crg_run "$@" ;;
  graphify-run)  shift; graphify_run "$@" ;;
  status)        status ;;
  *)             sed -n '2,17p' "$0" ;;
esac
exit 0
