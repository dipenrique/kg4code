#!/bin/sh
# kg-kit bootstrap: clone (or update) the kit, then run `kg-setup self-install`.
#
#   gh api repos/dipenrique/kg4code/contents/install.sh -H 'Accept: application/vnd.github.raw' | sh
#   curl -fsSL https://raw.githubusercontent.com/dipenrique/kg4code/main/install.sh | sh   # public repo only
#   sh install.sh [--claude] [--yes]                                                         # from a checkout
#
# Env: KG_KIT_REPO (owner/name), KG_KIT_URL (explicit clone URL), KG_KIT_DIR, KG_KIT_REF.
# Private repos: cloning tries SSH, then `gh`, then HTTPS with stored credentials.
set -eu
REPO=${KG_KIT_REPO:-dipenrique/kg4code}
DIR=${KG_KIT_DIR:-$HOME/.local/share/kg-kit}
REF=${KG_KIT_REF:-main}

say() { printf '%s\n' "kg-kit: $*"; }
die() { printf '%s\n' "kg-kit: error: $*" >&2; exit 1; }
command -v git > /dev/null 2>&1 || die "git is required"

clone() {   # <url>: quiet, non-interactive clone into $DIR
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
    git clone -q --branch "$REF" "$1" "$DIR" 2> /dev/null
}

if [ -d "$DIR/.git" ]; then
  say "updating $DIR"
  git -C "$DIR" pull -q --ff-only || die "git pull failed in $DIR (local changes?)"
elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2> /dev/null)" ]; then
  die "$DIR exists and is not a git clone; move it aside or set KG_KIT_DIR"
else
  mkdir -p "$(dirname "$DIR")"
  if [ -n "${KG_KIT_URL:-}" ]; then
    clone "$KG_KIT_URL" || die "could not clone $KG_KIT_URL"
  elif clone "git@github.com:$REPO.git"; then :
  elif command -v gh > /dev/null 2>&1 && gh repo clone "$REPO" "$DIR" -- -q --branch "$REF" > /dev/null 2>&1; then :
  elif clone "https://github.com/$REPO.git"; then :
  else
    die "could not clone $REPO (needs read access via SSH key, 'gh auth login', or HTTPS credentials)"
  fi
  say "cloned $REPO into $DIR"
fi

exec "$DIR/bin/kg-setup" self-install "$@"
