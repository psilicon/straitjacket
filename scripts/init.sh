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
# No `set -e`: explicit error handling also works when sourced from an interactive shell.

_sj_put() (  # Keep temp-file permissions and traps local to this write.
  local var="$1" value="$2" tmp status
  umask 077
  tmp="$(mktemp "$ENV_DIR/env.XXXXXX")" || return 1
  trap 'rm -f "$tmp"' EXIT
  # grep returns 1 when there are no retained lines; other failures must leave env intact.
  grep -v "^export ${var}=" "$ENV_FILE" > "$tmp"
  status=$?
  [ "$status" -le 1 ] || return "$status"
  printf 'export %s=%q\n' "$var" "$value" >> "$tmp" || return 1
  mv -f "$tmp" "$ENV_FILE" || return 1
)

_sj_token() { # prompt silently (secret); store only if something was entered
  local var="$1" label="$2" value
  read -rsp "$label (blank = keep current): " value || return 1
  echo
  if [ -n "$value" ]; then _sj_put "$var" "$value" || return 1; fi
}

_sj_init() {
  local ENV_DIR="$HOME/.config/straitjacket" ENV_FILE
  local _sj_name _sj_email _sj_codex
  ENV_FILE="$ENV_DIR/env"
  mkdir -p "$ENV_DIR" || return 1
  (umask 077; touch "$ENV_FILE" && chmod 600 "$ENV_FILE") || return 1

  echo "straitjacket — one-time setup for profile '${STRAITJACKET_PROFILE:-default}'"
  echo "Values are written to $ENV_FILE (private volume, never committed)."
  echo

  # --- Raw tokens ---
  _sj_token GH_TOKEN "GitHub PAT (recommend least-privilege, read-only access)" || return 1
  # Add more as sources are onboarded, e.g.:
  # _sj_token JENKINS_TOKEN "Jenkins API token"

  # --- Git identity (used when an agent commits inside the container) ---
  read -rp "Git author name for commits (blank = keep current): " _sj_name || return 1
  read -rp "Git author email for commits (blank = keep current): " _sj_email || return 1
  if [ -n "$_sj_name" ]; then
    _sj_put GIT_AUTHOR_NAME "$_sj_name" || return 1
    _sj_put GIT_COMMITTER_NAME "$_sj_name" || return 1
  fi
  if [ -n "$_sj_email" ]; then
    _sj_put GIT_AUTHOR_EMAIL "$_sj_email" || return 1
    _sj_put GIT_COMMITTER_EMAIL "$_sj_email" || return 1
  fi

  # --- Codex login (access token) ---
  # Codex authenticates non-interactively from an access token on stdin. The login is stored in
  # ~/.codex (a named volume), so it persists across rebuilds.
  read -rsp "Codex access token (blank = skip): " _sj_codex || return 1
  echo
  if [ -n "$_sj_codex" ]; then
    if printf '%s' "$_sj_codex" | codex login --with-access-token; then
      echo "✓ Codex logged in (stored on the codex volume)."
    else
      echo "✗ Codex login failed — check the token and re-run."
      return 1
    fi
  fi

  echo
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE" || return 1
    echo "✓ Tokens loaded into this shell. Verify GitHub with:  gh auth status"
  else
    echo "✓ Saved to $ENV_FILE — but NOT loaded into this shell yet."
    echo "  Load them now with:   source ~/.config/straitjacket/env"
    echo "  (Tip: next time run  source straitjacket-init  to skip this step.)"
  fi
  echo
  echo "Agents can commit inside the container using the git identity above."
  echo "Push access depends on your token permissions; Straitjacket does not enforce read-only access."
  echo
  echo "Last step — log in to Claude (persists across rebuilds):"
  echo "  claude        # follow the login prompt, then /exit"

  return 0
}

if _sj_init; then
  unset -f _sj_put _sj_token _sj_init
else
  echo "straitjacket: initialization failed; check the error above and re-run." >&2
  unset -f _sj_put _sj_token _sj_init
  # Return when sourced; exit only when executed as a separate script.
  return 1 2>/dev/null || exit 1
fi
