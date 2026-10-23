#!/bin/sh
# kg-kit bootstrap: clone (or update) the kit, then run `kg-setup self-install`.
#
#   curl -fsSL https://raw.githubusercontent.com/dipenrique/kg4code/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/dipenrique/kg4code/main/install.sh | sh -s -- --claude
#   sh install.sh [self-install flags]                       # from a checkout
#
# Flags after `--` go to `kg-setup self-install` (--claude, --yes, --dry-run, --no-tools).
# Env: KG_KIT_REPO (owner/name), KG_KIT_URL (explicit clone URL), KG_KIT_DIR, KG_KIT_REF.
# Clone order: anonymous HTTPS, then SSH, then `gh` (the last two cover forks/private mirrors).
#
# Everything lives in main(), called on the last line, so a truncated download runs nothing.

main() {
  set -eu
  REPO=${KG_KIT_REPO:-dipenrique/kg4code}
  DIR=${KG_KIT_DIR:-$HOME/.local/share/kg-kit}
  REF=${KG_KIT_REF:-main}

  _missing=""
  for _c in git bash jq perl awk; do command -v "$_c" > /dev/null 2>&1 || _missing="$_missing $_c"; done
  if [ -n "$_missing" ]; then
    die "missing required tools:$_missing
  macOS:          brew install$_missing
  Debian/Ubuntu:  sudo apt install$_missing"
  fi

  if [ -d "$DIR/.git" ]; then
    say "updating $DIR"
    git -C "$DIR" fetch -q origin "$REF" && git -C "$DIR" merge -q --ff-only FETCH_HEAD \
      || die "could not fast-forward $DIR (local changes?). Fix it, or remove it and re-run."
  elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2> /dev/null)" ]; then
    die "$DIR exists and is not a git clone; move it aside or set KG_KIT_DIR"
  else
    mkdir -p "$(dirname "$DIR")"
    if [ -n "${KG_KIT_URL:-}" ]; then
      clone "$KG_KIT_URL" || die "could not clone $KG_KIT_URL"
    elif clone "https://github.com/$REPO.git"; then :
    elif clone "git@github.com:$REPO.git"; then :
    elif command -v gh > /dev/null 2>&1 && gh repo clone "$REPO" "$DIR" -- -q --branch "$REF" > /dev/null 2>&1; then :
    else
      die "could not clone $REPO@$REF (check the network, or set KG_KIT_URL)"
    fi
    say "installed $REPO@$REF into $DIR"
  fi

  exec "$DIR/bin/kg-setup" self-install "$@"
}

say() { printf '%s\n' "kg-kit: $*"; }
die() { printf '%s\n' "kg-kit: error: $*" >&2; exit 1; }

clone() {   # <url>: quiet, non-interactive clone into $DIR; cleans up a failed attempt
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}" \
    git clone -q --branch "$REF" "$1" "$DIR" 2> /dev/null && return 0
  rm -rf "$DIR"; return 1
}

main "$@"
