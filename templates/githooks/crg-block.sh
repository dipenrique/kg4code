# kg-crg-start
# code-review-graph incremental update (detached; see kg-lib.sh kg_crg_from_git_hook)
command -v kg_crg_from_git_hook >/dev/null 2>&1 && kg_crg_from_git_hook __HOOK__ "$@"
:
# kg-crg-end
