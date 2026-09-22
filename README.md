# straitjacket

Run Claude Code and Codex inside a disposable container, against **any** directory on your host.
Nothing is copied into your projects — one image serves every target directory.

```bash
straitjacket up ~/repos       # build + start
straitjacket shell ~/repos    # you land in /workspaces/repos
codex                         # or claude
```

`DIR` defaults to the current directory, so day to day it's `cd ~/repos && straitjacket up && straitjacket shell`.

## How it works

`bin/straitjacket` is a thin wrapper over plain `docker build` / `docker run` / `docker exec`:

- **One image, `straitjacket`**, built from the `Dockerfile` here the first time you run `up`
  (or on `rebuild`). node:22 + Claude Code + Codex + the GitHub CLI, all from signed sources.
- **One container per target directory**, named `straitjacket-<dir basename>` so `docker ps`
  reads at a glance. Lookup is by the `straitjacket.workspace=<dir>` label, so the name is
  cosmetic; if two directories share a basename the second gets a short hash suffix.
- **The directory is bind-mounted at `/workspaces/<basename>`** and every command runs there as
  the unprivileged `node` user.
- **Setup scripts are baked into the image**, not read from the workspace — the workspace is an
  arbitrary directory that knows nothing about straitjacket. `straitjacket-postcreate` runs once
  when a container is created.

### Credentials live on named volumes, never from your host

| Volume | Mounted at | Holds |
|---|---|---|
| `straitjacket-<profile>-claude` | `~/.claude-config` | Claude Code login + config |
| `straitjacket-<profile>-codex` | `~/.codex` | Codex login + config |
| `straitjacket-<profile>-secrets` | `~/.config/straitjacket` | `env` file of raw tokens |

`CLAUDE_CONFIG_DIR` points Claude's *entire* config at the volume, instead of its default split
between `~/.claude/` and `~/.claude.json`. So logins survive rebuilds, and nothing from your host
config is visible inside.

One profile means **one login shared by every target directory**. Set `STRAITJACKET_PROFILE` to give
a project its own isolated credentials:

```bash
STRAITJACKET_PROFILE=client-x straitjacket up ~/work/client-x
```

Pass the same value to every later command for that directory.

### What `postcreate` does when a container is created

- Chowns the root-owned volume mounts to `node`.
- Sets `sandbox_mode = "danger-full-access"` in Codex's config. The container *is* the sandbox, and
  the Docker runtime blocks the user namespaces Codex's nested bubblewrap sandbox needs. Docker
  remains the outer boundary.
- Wires `gh auth git-credential` as git's credential helper.
- Marks all paths safe for git — the mount is host-owned and may contain many repos.
- Sources the token file from `.bashrc` and `.profile`; the image sets `BASH_ENV` to it as well, so
  tokens reach interactive, login, **and** non-interactive shells. The last one matters: Codex
  spawns non-interactive bash.

## Install

Requires **Docker**. Nothing else.

```bash
git clone git@github.com:psilicon/straitjacket.git
cd straitjacket
ln -s "$PWD/bin/straitjacket" /usr/local/bin/
```

Clone wherever you like — the symlink is built from `$PWD`, so it always points at the copy you
just cloned. Prefix the `ln` with `sudo` if `/usr/local/bin` isn't writable for you.

The wrapper resolves symlinks to find its own Dockerfile, so linking it onto `PATH` is fine — adding
`bin/` to `PATH` works too. Set `STRAITJACKET_HOME` to override where it looks.

## First run

```bash
straitjacket up ~/repos
straitjacket init ~/repos            # GH token, git identity, Codex login — once per profile
straitjacket claude ~/repos          # log in to Claude, then /exit
```

`init` is also available inside the container as `source straitjacket-init`.

## Commands

| | |
|---|---|
| `up [DIR] [-- ARGS]` | Build the image if missing, then create or start the container; extra `ARGS` pass through to `docker run` |
| `rebuild [DIR]` | Rebuild the image and recreate the container |
| `shell [DIR]` | Interactive login shell |
| `exec [DIR] -- CMD` | Run a command |
| `claude` / `codex [DIR]` | Launch an agent directly |
| `init [DIR]` | One-time token / identity / Codex login setup |
| `down [DIR]` | Remove the container; image, volumes and logins survive |
| `list` | Show straitjacket containers and the directories they serve |

## Caveats

- **Do not attach VS Code to the container.** Attaching forwards your **host git credentials** and
  **SSH agent** in, which voids the isolation this exists to provide. Use the CLI.
- **Mount granularity is the directory you name.** Point at `~/repos`, not `~`, unless you mean to
  hand an agent your whole home directory. To add more mounts:
  `straitjacket up ~/repos -- --mount type=bind,source=/data,target=/data`.
  Extra `docker run` args apply at creation only; use `rebuild` to change them later.
- **The container has no push credential** beyond whatever token you enter in `init`. Agents can
  commit inside; pushing is normally done from the host.
- **Linux hosts:** the image is built with `node` renumbered to your uid/gid, so files the agent
  writes into the mount are owned by you. The image is therefore per-user; rebuild if you switch
  accounts. macOS translates ownership at the mount, so nothing special happens there.

## Layout

```text
straitjacket/
├── bin/straitjacket          # the wrapper CLI
├── Dockerfile                # node:22 + Claude Code (signed apt) + gh (signed apt) + @openai/codex
└── scripts/
    ├── postCreate.sh         # → /usr/local/bin/straitjacket-postcreate
    └── init.sh               # → /usr/local/bin/straitjacket-init
```
