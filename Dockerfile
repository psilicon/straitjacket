# The image every straitjacket container runs from. Built by `straitjacket up` as `straitjacket`.
#
# Base: Microsoft's node:22 dev image — Debian, Node 22, git, sudo, and an unprivileged `node`
# user (uid 1000) with passwordless sudo. Nothing devcontainer-specific is used from it.
FROM mcr.microsoft.com/devcontainers/javascript-node:22

# Tools needed to add the signed apt repos below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && rm -rf /var/lib/apt/lists/*

# Claude Code — official signed apt repo (GPG-verified by apt).
# Key fingerprint: 31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /etc/apt/keyrings/claude-code.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/latest latest main" \
      > /etc/apt/sources.list.d/claude-code.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends claude-code \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI — official signed apt repo.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Codex CLI — official SCOPED npm package. NOT the unscoped "codex" (unrelated 2012 project).
RUN npm install -g @openai/codex

# Grok Build — official installer (https://x.ai/cli/install.sh).
# The script keeps the binary under $HOME/.grok. That path is a named volume for login,
# config, and sessions, so install into a system home: a volume mount would hide a binary
# placed in /home/node/.grok. The script is saved to a file first so a failed download
# fails the build. It also links `grok` and `agent` into /usr/local/bin when that
# directory is writable; the explicit links below keep that true even if PATH differs.
RUN mkdir -p /opt/grok-home \
 && curl -fsSL https://x.ai/cli/install.sh -o /tmp/grok-install.sh \
 && HOME=/opt/grok-home bash /tmp/grok-install.sh \
 && rm -f /tmp/grok-install.sh \
 && chmod -R a+rX /opt/grok-home \
 && ln -sfn /opt/grok-home/.grok/bin/grok /usr/local/bin/grok \
 && ln -sfn /opt/grok-home/.grok/bin/agent /usr/local/bin/agent \
 && grok --version

# Bake the setup scripts into the image rather than reading them from the workspace — the
# workspace is an arbitrary host directory that knows nothing about straitjacket.
COPY scripts/postCreate.sh /usr/local/bin/straitjacket-postcreate
COPY scripts/init.sh       /usr/local/bin/straitjacket-init
RUN chmod 0755 /usr/local/bin/straitjacket-postcreate /usr/local/bin/straitjacket-init

# On Linux hosts a bind mount carries ownership straight through, so `node` must share the host
# user's uid/gid or files the agent writes land on disk owned by someone else. The wrapper passes
# the host ids there; macOS translates ownership at the mount, so the defaults are kept.
ARG USER_UID=1000
ARG USER_GID=1000
RUN if [ "$USER_UID" != "$(id -u node)" ] || [ "$USER_GID" != "$(id -g node)" ]; then \
      groupmod --gid "$USER_GID" node \
   && usermod --uid "$USER_UID" --gid "$USER_GID" node \
   && chown -R "$USER_UID:$USER_GID" /home/node; \
    fi

# Relocate Claude's entire user config (credentials + the ~/.claude.json config + settings) onto
# the volume the wrapper mounts here, instead of its default split between ~/.claude/ and
# ~/.claude.json. BASH_ENV makes non-interactive bash (commands claude, codex, or grok spawn) source the
# token file too — interactive and login shells get it from .bashrc/.profile via postcreate.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude-config \
    BASH_ENV=/home/node/.config/straitjacket/env

USER node
