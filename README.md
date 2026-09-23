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
  (or on `rebuild`). Microsoft's Node 22 devcontainer image + Claude Code from its apt
  repository + Codex from `@openai/codex` on npm + the GitHub CLI from its apt repository.
- **One container per target directory**, named `straitjacket-<dir basename>` so `docker ps`
  reads at a glance. Lookup is by the `straitjacket.workspace=<dir>` label, so the name is
  cosmetic; if two directories share a basename the second gets a short hash suffix.
- **The directory is bind-mounted at `/workspaces/<basename>`** and every command runs there as
  the unprivileged `node` user.
- **Setup scripts are baked into the image**, not read from the workspace — the workspace is an
  arbitrary directory that knows nothing about straitjacket. `straitjacket-postcreate` runs once
  when a container is created.

### Credentials live on named volumes

| Volume | Mounted at | Holds |
|---|---|---|
| `straitjacket-<profile>-claude` | `~/.claude-config` | Claude Code login + config |
| `straitjacket-<profile>-codex` | `~/.codex` | Codex login + config |
| `straitjacket-<profile>-secrets` | `~/.config/straitjacket` | `env` file of raw tokens |

`CLAUDE_CONFIG_DIR` points Claude's *entire* config at the volume, instead of its default split
between `~/.claude/` and `~/.claude.json`. Logins survive rebuilds. By default, Straitjacket mounts
only the selected workspace and its named credential volumes; it does not mount your host
configuration directories. Mounting your home directory or adding Docker mounts can expose them.

One profile means **one login shared by every target directory**. Set `STRAITJACKET_PROFILE` to give
a project its own isolated credentials:

```bash
STRAITJACKET_PROFILE=client-x straitjacket up ~/work/client-x
```

Pass the same value to every later command for that directory. Commands reject an existing
container with a different profile. To switch profiles, run `down` with the old profile, then
`up` with the new one. Agents can access credentials shared by their profile.

### Updates and rebuilds

Tool versions follow a **rolling** policy: the base image tag and package versions are unpinned.
`straitjacket rebuild [DIR]` always builds with `--pull --no-cache` to refresh the base image and
installed tools. Ordinary `up` reuses a matching local image; it does not check for tool updates.
The apt repositories verify packages using keys downloaded during the build; the build does not
independently verify key fingerprints or pin all inputs. This is not a reproducible build or an
end-to-end supply-chain signature guarantee.

Images carry a Straitjacket marker and a fingerprint of the Dockerfile, setup scripts,
`.dockerignore`, and effective UID/GID. `up` asks you to rebuild if the image is unrecognized or
does not match. These labels detect accidental reuse, not maliciously forged images.

After a successful build, `rebuild` stops and removes only the selected workspace container,
terminating its active agent sessions and processes. Its disposable filesystem is lost; the
bind-mounted workspace and named credential volumes are preserved. Other existing containers
keep running their current image. Newly created containers use the refreshed shared image.

To recreate a container without refreshing tools, use `down` followed by `up`. Supply any custom
Docker run arguments again when recreating or rebuilding; they are not saved by the wrapper.

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
| `up [DIR] [-- ARGS]` | Build if missing, verify an existing image, then create or start the container; extra `ARGS` pass through to `docker run` |
| `rebuild [DIR] [-- ARGS]` | Refresh the base image and tools, then recreate the selected container; extra `ARGS` pass through to `docker run` |
| `shell [DIR]` | Interactive login shell |
| `exec [DIR] -- CMD` | Run a command |
| `claude` / `codex [DIR] [-- ARGS]` | Launch an agent directly with optional arguments, e.g. `straitjacket codex -- --help` |
| `init [DIR]` | One-time token / identity / Codex login setup |
| `down [DIR]` | Remove the container; image, volumes and logins survive |
| `list` | Show straitjacket containers and the directories they serve |

## Caveats

- **Inspect your Dev Containers configuration before attaching VS Code.** Depending on your
  client and settings, attaching may forward host Git credentials or your SSH agent. The CLI
  does not forward these by default.
- **Mount granularity is the directory you name.** Point at `~/repos`, not `~`, unless you mean to
  hand an agent your whole home directory. To add more mounts:
  `straitjacket up ~/repos -- --mount type=bind,source=/data,target=/data`.
  Extra `docker run` args apply at creation only; supply them again to `rebuild` to change them later.
- **Use a least-privilege, read-only GitHub token.** `init` does not validate or restrict its
  permissions. The token is available to container processes and Git's credential helper;
  a token with repository write access can allow agents to push. Push prevention depends on
  the token's permissions, not enforcement by Straitjacket.
- **Agents can modify the mounted workspace.** The `node` user has passwordless sudo inside
  the container. Docker is the outer boundary, not a restriction on access to mounted files
  or the profile's credentials. Additional Docker arguments can weaken that boundary.
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

## Development checks

Run `bash -n bin/straitjacket scripts/*.sh` and `python3 -m unittest discover -s tests -v`.
The regression tests use a mock Docker command and temporary files; they do not require a Docker
daemon or touch real containers or credentials.
