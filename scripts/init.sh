#!/usr/bin/env bash
#
# One-time (per fresh volume set) setup: enter tokens + git identity, and log in to Codex.
# Baked into the image at /usr/local/bin/straitjacket-init, so run it from anywhere:
#
#   source straitjacket-init   → values are loaded into THIS shell immediately
#   straitjacket-init          → values are saved; reload with `source ~/.config/straitjacket/env`
#
# (`source` searches PATH for a bare filename, so the first form works without a path.)
#
# No `set -e` / `exit` on purpose, so it's safe to `source` without disturbing your shell.

# Were we sourced? If so, never exit the user's shell; load the vars at the end instead.
_sj_sourced=0
[ "${BASH_SOURCE[0]:-$0}" != "$0" ] && _sj_sourced=1

ENV_DIR="$HOME/.config/straitjacket"
ENV_FILE="$ENV_DIR/env"
mkdir -p "$ENV_DIR"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

_sj_put() {   # write/replace an exported var in the env file
  local var="$1" value="$2"
  grep -v "^export ${var}=" "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  printf 'export %s=%q\n' "$var" "$value" >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

_sj_token() { # prompt silently (secret); store only if something was entered
  local var="$1" label="$2" value
  read -rsp "$label (blank = keep current): " value
  echo
  [ -n "$value" ] && _sj_put "$var" "$value"
}

echo "straitjacket — one-time setup for profile '${STRAITJACKET_PROFILE:-default}'"
echo "Values are written to $ENV_FILE (private volume, never committed)."
echo

# --- Raw tokens ---
_sj_token GH_TOKEN "GitHub read-only PAT"
# Add more as sources are onboarded, e.g.:
# _sj_token JENKINS_TOKEN "Jenkins API token"

# --- Git identity (used when an agent commits inside the container) ---
read -rp "Git author name for commits (blank = keep current): " _sj_name
read -rp "Git author email for commits (blank = keep current): " _sj_email
if [ -n "$_sj_name" ]; then
  _sj_put GIT_AUTHOR_NAME "$_sj_name"
  _sj_put GIT_COMMITTER_NAME "$_sj_name"
fi
if [ -n "$_sj_email" ]; then
  _sj_put GIT_AUTHOR_EMAIL "$_sj_email"
  _sj_put GIT_COMMITTER_EMAIL "$_sj_email"
fi

# --- Codex login (access token) ---
# Codex authenticates non-interactively from an access token on stdin. The login is stored in
# ~/.codex (a named volume), so it persists across rebuilds.
read -rsp "Codex access token (blank = skip): " _sj_codex
echo
if [ -n "$_sj_codex" ]; then
  if printf '%s' "$_sj_codex" | codex login --with-access-token; then
    echo "✓ Codex logged in (stored on the codex volume)."
  else
    echo "✗ Codex login failed — check the token and re-run."
  fi
fi

echo
if [ "$_sj_sourced" = 1 ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  echo "✓ Tokens loaded into this shell. Verify GitHub with:  gh auth status"
else
  echo "✓ Saved to $ENV_FILE — but NOT loaded into this shell yet."
  echo "  Load them now with:   source ~/.config/straitjacket/env"
  echo "  (Tip: next time run  source straitjacket-init  to skip this step.)"
fi
echo
echo "Agents can commit inside the container using the git identity above."
echo "Pushing is done from the host — the container has no push credential."
echo
echo "Last step — log in to Claude (persists across rebuilds):"
echo "  claude        # follow the login prompt, then /exit"

# Tidy up our helpers / temp vars so they don't leak into your shell when sourced.
unset -f _sj_put _sj_token 2>/dev/null || true
unset _sj_sourced _sj_name _sj_email _sj_codex 2>/dev/null || true
