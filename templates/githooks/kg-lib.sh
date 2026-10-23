# shellcheck shell=sh
# kg-lib.sh — shared helpers for knowledge-graph auto-refresh
# (graphify + code-review-graph, a.k.a. CRG).
#
# Sourced by the git hooks in this folder and by kg-hook.sh (GitHub Copilot in
# VS Code / Copilot CLI agent hooks). The sourcing script must set KG_DIR to
# this folder first. POSIX sh only, best-effort everywhere: nothing in here may
# fail, block, or slow down the caller. Heavy work is always detached, niced,
# resource-gated, time-boxed and single-flight (one lock per repo per tool).
#
# Docs: docs/agents/knowledge-graph.md

# ------------------------------------------------------------------ settings --
# Every value can be overridden from the environment.
: "${KG_HOOKS_DISABLE:=0}"            # 1 = all kg hooks become no-ops
: "${KG_LOG_DIR:=$HOME/.cache/knowledge-graph-hooks}"
: "${KG_NICE:=10}"                    # priority of background graph jobs
: "${KG_MAX_CPU_PCT:=85}"             # macOS: skip rebuilds when system CPU % is above this
: "${KG_MAX_LOAD_RATIO:=1.5}"         # Linux: skip rebuilds when (1-min load / cores) is above this
: "${KG_MIN_FREE_MB:=1536}"           # skip rebuilds when available memory (MB) is below this
: "${KG_CRG_TIMEOUT:=300}"            # seconds; background code-review-graph job
: "${KG_GRAPHIFY_TIMEOUT:=600}"       # seconds; background graphify job
: "${KG_GRAPHIFY_WORKERS:=2}"         # GRAPHIFY_MAX_WORKERS for hook-driven rebuilds
: "${KG_CRG_FULL_THRESHOLD:=200}"     # post-checkout: changed files above this -> full CRG build
: "${KG_CRG_EMBED:=auto}"             # auto = embed on git events only if code-review-graph[embeddings] is installed
: "${KG_LOCK_STALE_MIN:=20}"          # a lock older than this many minutes is treated as abandoned
: "${KG_SESSION_GRAPHIFY_REFRESH:=1}" # agent session start: refresh a stale graphify graph in background
KG_TMP="${TMPDIR:-/tmp}"
KG_TMP="${KG_TMP%/}/kg-hooks-$(id -u 2>/dev/null || echo 0)"

# ------------------------------------------------------------------- basics --
kg_disabled() { [ "$KG_HOOKS_DISABLE" = "1" ]; }

kg_log() {
  mkdir -p "$KG_LOG_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$KG_LOG_DIR/hooks.log" 2>/dev/null
  return 0
}

# kg_bin <name> — absolute path of a CLI even when the hook runs with a thin PATH.
kg_bin() {
  case "$1" in
    code-review-graph) [ -n "${KG_CRG_BIN:-}" ] && [ -x "$KG_CRG_BIN" ] && { printf '%s\n' "$KG_CRG_BIN"; return 0; } ;;
    graphify) [ -n "${KG_GRAPHIFY_BIN:-}" ] && [ -x "$KG_GRAPHIFY_BIN" ] && { printf '%s\n' "$KG_GRAPHIFY_BIN"; return 0; } ;;
  esac
  command -v "$1" 2>/dev/null && return 0
  for _kg_d in "$HOME/.local/bin" "$HOME/miniconda3/bin" "$HOME/anaconda3/bin" "$HOME/miniforge3/bin" \
               /opt/homebrew/bin /usr/local/bin; do
    [ -x "$_kg_d/$1" ] && { printf '%s\n' "$_kg_d/$1"; return 0; }
  done
  return 1
}

kg_toplevel() { [ -n "$1" ] && [ -d "$1" ] && git -C "$1" rev-parse --show-toplevel 2>/dev/null; }

# kg_json_get <key> <json> — first string value for key (flat, good enough for hook payloads).
kg_json_get() {
  printf '%s' "$2" | tr '\n' ' ' \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# kg_json_escape — stdin text -> JSON string body (no surrounding quotes).
kg_json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | awk 'BEGIN { ORS = "" } NR > 1 { print "\\n" } { print }'
}

# kg_once <namespace> <payload> — 0 the first time a given payload is seen, 1 after.
# Multi-root VS Code workspaces load .github/hooks/*.json from every folder, so the
# same hook can fire once per folder for one event; this keeps the work single.
kg_once() {
  mkdir -p "$KG_TMP" 2>/dev/null || return 0
  _kg_key=$(printf '%s' "$2" | cksum | awk '{ print $1 "-" $2 }')
  mkdir "$KG_TMP/$1-$_kg_key" 2>/dev/null
}

kg_prune_tmp() {
  [ -d "$KG_TMP" ] && find "$KG_TMP" -mindepth 1 -maxdepth 1 -mmin +720 -exec rm -rf {} + 2>/dev/null
  return 0
}

# ------------------------------------------------------------ resource gate --
# 0 when the machine has headroom for a background rebuild, 1 otherwise.
kg_resources_ok() {
  [ "${KG_SKIP_RESOURCE_CHECK:-0}" = "1" ] && return 0
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      _kg_n=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
      # macOS load average counts blocked threads and is unreliable; sum per-process CPU instead.
      _kg_cpu=$(ps -A -o %cpu= 2>/dev/null | awk -v n="$_kg_n" '{ s += $1 } END { if (n < 1) n = 1; printf "%d", s / n }')
      if [ -n "$_kg_cpu" ] && [ "$_kg_cpu" -gt "$KG_MAX_CPU_PCT" ] 2>/dev/null; then
        kg_log "skip: system CPU ${_kg_cpu}% > ${KG_MAX_CPU_PCT}%"; return 1
      fi
      _kg_ps=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
      _kg_mem=$(vm_stat 2>/dev/null | awk -v ps="$_kg_ps" '
        /Pages free:/        { gsub(/\./, "", $3); f = $3 }
        /Pages inactive:/    { gsub(/\./, "", $3); i = $3 }
        /Pages speculative:/ { gsub(/\./, "", $3); s = $3 }
        END { printf "%d", (f + i + s) * ps / 1048576 }')
      ;;
    Linux)
      _kg_n=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
      _kg_load=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)
      if [ -n "$_kg_load" ] && awk -v l="$_kg_load" -v n="$_kg_n" -v r="$KG_MAX_LOAD_RATIO" \
           'BEGIN { if (n < 1) n = 1; exit !(l / n > r) }'; then
        kg_log "skip: load $_kg_load > ${KG_MAX_LOAD_RATIO} x $_kg_n cores"; return 1
      fi
      _kg_mem=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null)
      ;;
    *) return 0 ;;
  esac
  if [ -n "$_kg_mem" ] && [ "$_kg_mem" -lt "$KG_MIN_FREE_MB" ] 2>/dev/null; then
    kg_log "skip: available memory ${_kg_mem}MB < ${KG_MIN_FREE_MB}MB"; return 1
  fi
  return 0
}

# ------------------------------------------------------- locks / detaching --
# kg_lockdir <tool> <repo> — lock path kept outside tool-owned folders.
kg_lockdir() {
  mkdir -p "$KG_TMP" 2>/dev/null
  printf '%s/lock-%s-%s\n' "$KG_TMP" "$1" "$(printf '%s' "$2" | cksum | awk '{ print $1 }')"
}

# kg_lock_busy <dir> — 0 when a live (non-stale) job holds the lock.
kg_lock_busy() {
  [ -d "$1" ] || return 1
  [ -n "$(find "$1" -maxdepth 0 -mmin +"$KG_LOCK_STALE_MIN" 2>/dev/null)" ] && return 1
  _kg_pid=$(cat "$1/pid" 2>/dev/null)
  [ -z "$_kg_pid" ] && return 0                       # just created, pid not written yet
  kill -0 "$_kg_pid" 2>/dev/null
}

# kg_lock_acquire <dir> — atomic (mkdir); records $$; clears stale locks.
kg_lock_acquire() {
  if ! mkdir "$1" 2>/dev/null; then
    kg_lock_busy "$1" && return 1
    rm -rf "$1" 2>/dev/null
    mkdir "$1" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$1/pid" 2>/dev/null
  return 0
}

# kg_with_timeout <seconds> <cmd...>
kg_with_timeout() {
  _kg_s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$_kg_s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$_kg_s" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$_kg_s" "$@"
  else "$@"
  fi
}

# kg_spawn <cmd...> — fully detached, niced; never holds the caller's stdout/stderr.
kg_spawn() {
  mkdir -p "$KG_LOG_DIR" 2>/dev/null
  ( nohup nice -n "$KG_NICE" "$@" >> "$KG_LOG_DIR/jobs.log" 2>&1 < /dev/null & ) > /dev/null 2>&1
  return 0
}

# --------------------------------------------------------- code-review-graph --
kg_crg_fingerprint() {
  {
    git -C "$1" rev-parse HEAD 2>/dev/null
    git -C "$1" diff HEAD --no-ext-diff --no-color 2>/dev/null | cksum
    git -C "$1" ls-files --others --exclude-standard 2>/dev/null | cksum
  } | cksum | awk '{ print $1 "-" $2 }'
}

# kg_crg_changed <repo> — 0 when the working tree differs from the last successful update.
kg_crg_changed() {
  _kg_f="$1/.code-review-graph/.kg-fingerprint"
  [ -f "$_kg_f" ] || return 0
  [ "$(cat "$_kg_f" 2>/dev/null)" = "$(kg_crg_fingerprint "$1")" ] || return 0
  _kg_new=$(cd "$1" 2>/dev/null && git ls-files --others --exclude-standard 2>/dev/null \
    | while IFS= read -r _kg_p; do [ "$_kg_p" -nt "$_kg_f" ] && { echo y; break; }; done)
  [ -n "$_kg_new" ]
}

kg_crg_head_sha() {
  [ -f "$1/.code-review-graph/graph.db" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 -cmd '.timeout 1500' "$1/.code-review-graph/graph.db" \
    "select value from metadata where key='git_head_sha'" 2>/dev/null | head -n 1
}

kg_crg_counts() {
  [ -f "$1/.code-review-graph/graph.db" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 -separator ' ' -cmd '.timeout 1500' "$1/.code-review-graph/graph.db" \
    "select (select count(*) from nodes), (select count(*) from edges)" 2>/dev/null \
    | awk 'NF == 2 { printf "%s nodes/%s edges", $1, $2 }'
}

# kg_crg_queue <repo> <update|update-fast|build> <reason> — 0 when a job was queued.
kg_crg_queue() {
  kg_disabled && return 1
  [ -d "$1/.code-review-graph" ] || return 1
  kg_bin code-review-graph > /dev/null || return 1
  if kg_lock_busy "$(kg_lockdir crg "$1")"; then kg_log "crg busy, skip ($3) $1"; return 1; fi
  kg_resources_ok || return 1
  kg_spawn sh "$KG_DIR/kg-hook.sh" crg-run "$1" "$2" "$3"
  kg_log "crg queued $2 ($3) $1"
  return 0
}

# ----------------------------------------------------------------- graphify --
kg_graphify_built_commit() {
  [ -f "$1/graphify-out/GRAPH_REPORT.md" ] || return 0
  sed -n 's/.*Built from commit: `\([0-9a-f]*\)`.*/\1/p' "$1/graphify-out/GRAPH_REPORT.md" 2>/dev/null | head -n 1
}

kg_graphify_summary() {
  [ -f "$1/graphify-out/GRAPH_REPORT.md" ] || return 0
  sed -n 's/^- \([0-9][0-9]* nodes .*communities\).*/\1/p' "$1/graphify-out/GRAPH_REPORT.md" 2>/dev/null \
    | head -n 1 | sed 's/ (.*//'
}

# kg_graphify_queue <repo> <reason> — 0 when a job was queued. Never builds a first graph.
kg_graphify_queue() {
  kg_disabled && return 1
  [ -f "$1/graphify-out/graph.json" ] || return 1
  kg_bin graphify > /dev/null || return 1
  if kg_lock_busy "$(kg_lockdir graphify "$1")"; then kg_log "graphify busy, skip ($2) $1"; return 1; fi
  kg_resources_ok || return 1
  kg_spawn sh "$KG_DIR/kg-hook.sh" graphify-run "$1" "$2"
  kg_log "graphify queued ($2) $1"
  return 0
}

# ------------------------------------------------------------ repo discovery --
# kg_repos <payload-json> — newline list of git toplevels relevant to an agent
# event: the payload cwd, the hook's own cwd, every folder of a *.code-workspace
# found at those roots (multi-root workspaces), and KG_EXTRA_REPOS (':'-separated).
kg_repos() {
  _kg_base=$({ kg_toplevel "$(kg_json_get cwd "$1")"; kg_toplevel "$PWD"; } | awk 'NF && !seen[$0]++')
  {
    printf '%s\n' "$_kg_base"
    printf '%s\n' "$_kg_base" | while IFS= read -r _kg_root; do
      [ -n "$_kg_root" ] || continue
      for _kg_ws in "$_kg_root"/*.code-workspace; do
        [ -f "$_kg_ws" ] || continue
        sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_kg_ws" | while IFS= read -r _kg_p; do
          case "$_kg_p" in /*) _kg_abs="$_kg_p" ;; *) _kg_abs="$_kg_root/$_kg_p" ;; esac
          kg_toplevel "$_kg_abs"
        done
      done
    done
    printf '%s\n' "${KG_EXTRA_REPOS:-}" | tr ':' '\n' | while IFS= read -r _kg_p; do kg_toplevel "$_kg_p"; done
  } | awk 'NF && !seen[$0]++'
}

# ----------------------------------------------------------------- git hooks --
# Called first in every git hook: lower priority, cap graphify workers and gate
# graphify's own (upstream-generated) block via GRAPHIFY_SKIP_HOOK.
kg_git_prelude() {
  if kg_disabled; then export GRAPHIFY_SKIP_HOOK=1; return 0; fi
  renice -n "$KG_NICE" -p $$ > /dev/null 2>&1 || true
  export GRAPHIFY_MAX_WORKERS="${GRAPHIFY_MAX_WORKERS:-$KG_GRAPHIFY_WORKERS}"
  export GRAPHIFY_REBUILD_TIMEOUT="${GRAPHIFY_REBUILD_TIMEOUT:-$KG_GRAPHIFY_TIMEOUT}"
  _kg_top=$(git rev-parse --show-toplevel 2>/dev/null)
  # Only refresh an existing graphify graph; never start a surprise first build.
  if [ -n "$_kg_top" ] && [ ! -f "$_kg_top/graphify-out/graph.json" ]; then export GRAPHIFY_SKIP_HOOK=1; fi
  if [ "${GRAPHIFY_SKIP_HOOK:-0}" != "1" ] && ! kg_resources_ok; then
    export GRAPHIFY_SKIP_HOOK=1
    echo "[kg] graphify rebuild skipped: machine busy (the next commit or agent session retries)"
  fi
  return 0
}

# kg_crg_from_git_hook <hook-name> [git hook args...]
kg_crg_from_git_hook() {
  _kg_hook="$1"; shift
  kg_disabled && return 0
  _kg_repo=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -d "$_kg_repo/.code-review-graph" ] || return 0
  _kg_gd=$(cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd)
  _kg_cd=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)
  [ -n "$_kg_cd" ] && [ "$_kg_gd" != "$_kg_cd" ] && return 0     # linked worktree
  _kg_mode=update
  case "$_kg_hook" in
    post-commit)
      # Each rebase step commits; post-rewrite refreshes once at the end instead.
      { [ -d "$_kg_gd/rebase-merge" ] || [ -d "$_kg_gd/rebase-apply" ]; } && return 0
      ;;
    post-checkout)
      [ "${3:-0}" = "1" ] || return 0                                 # file checkout, not a branch switch
      [ "$1" = "$2" ] && return 0
      case "$1" in 0000000000000000000000000000000000000000) _kg_mode=build ;; esac
      _kg_n=$(git diff --name-only "$1" "$2" 2>/dev/null | wc -l | tr -d ' ')
      [ "${_kg_n:-0}" -gt "$KG_CRG_FULL_THRESHOLD" ] 2>/dev/null && _kg_mode=build
      ;;
  esac
  if kg_crg_queue "$_kg_repo" "$_kg_mode" "$_kg_hook"; then
    echo "[kg] code-review-graph $_kg_mode queued in background (log: $KG_LOG_DIR)"
  fi
  return 0
}
