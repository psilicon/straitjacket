#!/usr/bin/env bash
set -euo pipefail

# Runs on every container create, non-interactively, as `node` with cwd = the mounted workspace.

# Named volumes mount root-owned; hand them to the container user so it can write logins/tokens.
sudo mkdir -p "$HOME/.claude-config" "$HOME/.codex" "$HOME/.grok" "$HOME/.config/straitjacket"
sudo chown -R node:node "$HOME/.claude-config" "$HOME/.codex" "$HOME/.grok" "$HOME/.config"

# Codex runs in full-access mode: this container is the sandbox, and the Docker runtime blocks
# the user namespaces Codex's nested bwrap sandbox needs. (Docker stays the outer boundary.)
cfg="$HOME/.codex/config.toml"
touch "$cfg"
if ! grep -q '^sandbox_mode' "$cfg"; then
  { echo 'sandbox_mode = "danger-full-access"'; cat "$cfg"; } > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
fi

# Let raw `git` commands authenticate with gh's token.
git config --global 'credential.https://github.com.helper' '!gh auth git-credential'

# Everything mounted is host-owned, and the workspace may hold many repos at unknown depths,
# so blanket-trust rather than enumerating. The container is disposable by design.
git config --global --add safe.directory '*'

# Load persisted tokens (GH_TOKEN, git identity) in every kind of shell:
#   ~/.bashrc → interactive   ~/.profile → login   (non-interactive bash: BASH_ENV, set in the Dockerfile)
touch "$HOME/.config/straitjacket/env"
chmod 600 "$HOME/.config/straitjacket/env"
hook='[ -f "$HOME/.config/straitjacket/env" ] && . "$HOME/.config/straitjacket/env"'
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$rc"
  grep -q '.config/straitjacket/env' "$rc" || echo "$hook" >> "$rc"
done

echo "postCreate complete."
if [ ! -s "$HOME/.config/straitjacket/env" ]; then
  echo "First run on these volumes — inside the container:"
  echo "  source straitjacket-init   # tokens + git identity + Codex login"
  echo "  claude                     # log in, then /exit"
  echo "  grok                       # log in, then /exit"
fi
