# AI Agent Sandbox

Rootless Podman containers to run AI coding agents (Claude Code, Claude Code via Vertex AI, Codex, Cursor Agent, opencode) in isolation. Each agent runs in a hardened, read-only container with minimal capabilities, resource limits and an isolated network stack.

## Structure

```
ai-sandbox/
├── base/
│   ├── Containerfile          # Base image (Fedora 44, Node.js, Python, Git, ripgrep, zellij, …)
│   ├── ai-sandbox-supervise   # Entrypoint shim: runs the agent inside zellij for --web
│   └── zellij.kdl             # zellij config used by --web sessions
├── bpf/
│   ├── block_commands.bpf.c   # BPF LSM program (hooks bprm_check_security)
│   ├── block_commands.h       # Shared structures (blocked_cmd_key)
│   ├── config.h               # Configuration defines (MAX_BIN_LEN, etc.)
│   ├── loader.c               # Userspace loader (libbpf skeleton)
│   ├── Makefile               # Build system for BPF program and loader
│   └── README.md              # BPF component documentation
├── claude-code/
│   └── Containerfile          # Claude Code (native installer + npm fallback)
├── codex/
│   └── Containerfile          # OpenAI Codex CLI
├── cursor-agent/
│   ├── Containerfile          # Cursor Agent CLI (installed to /opt to survive tmpfs)
│   └── entrypoint.sh          # Prepares tmpfs home, then hands off to the supervisor
├── opencode/
│   ├── Containerfile          # opencode CLI (any OpenAI-compatible endpoint)
│   └── entrypoint.sh          # Generates opencode.json from AI_SANDBOX_OPENCODE_*
├── web/
│   ├── ai-sandbox-web         # Web dashboard (Python 3, standard library only)
│   ├── ai-sandbox-web.service # systemd user unit for the dashboard
│   ├── assets.sha256          # Pinned browser assets, fetched by install.sh
│   └── static/                # Dashboard UI and browser terminal
├── test/
│   ├── test_bpf_blocker.sh   # End-to-end tests for BPF command blocker
│   └── test_webui.sh         # End-to-end tests for the web UI (no root needed)
├── install.sh                 # Installer (and uninstaller) script
├── ai-sandbox                 # Wrapper to start agents
├── ai-sandbox-build           # Build script for container images
├── LICENSE                    # GPLv3
└── README.md
```

## Requirements

- [Podman](https://podman.io/) (rootless) — tested with v4+
- [passt/pasta](https://passt.top/) — network backend (default mode; `slirp4netns` works as fallback)
- Git
- cgroups v2 enabled (default on recent Fedora, Arch, Debian 12+, Ubuntu 24.04+)
- Python 3.9+ and a systemd user manager — only for the optional [web UI](#web-ui)

The installer checks all of these automatically. See [install.sh](#install) for details.

## Quick Start

```bash
# 1. Install (checks prerequisites, builds images, installs to ~/.local/bin)
./install.sh

# 2. Configure API keys (the env file is created automatically by install.sh)
vi ~/.config/ai-sandbox/env
# Uncomment and fill in the keys you need:
#   ANTHROPIC_API_KEY=sk-ant-...
#   OPENAI_API_KEY=sk-...
#   CURSOR_API_KEY=...
#   AI_SANDBOX_OPENCODE_API_KEY=...
#
# For Claude via Vertex AI, also set:
#   CLAUDE_CODE_USE_VERTEX=1
#   CLOUD_ML_REGION=global
#   ANTHROPIC_VERTEX_PROJECT_ID=<your-gcp-project-id>

# 3. Use it!
ai-sandbox claude ~/projects/my-repo
ai-sandbox claude-vertex ~/projects/my-repo   # via Vertex AI + GCP credentials
ai-sandbox codex  .
ai-sandbox cursor ~/projects/other -- chat "find bugs"
ai-sandbox opencode ~/projects/my-repo        # opencode, Ollama Cloud by default
ai-sandbox claude                              # uses current directory
ai-sandbox claude ~/projects/api --dir ~/projects/web   # two repos in one sandbox
```

## Install

The `install.sh` script handles the full setup:

```bash
./install.sh              # full install: prerequisites check, images, BPF (if possible)
./install.sh --no-build   # install the script only, skip container image build
./install.sh --with-web   # install the web dashboard without being asked
./install.sh --no-web     # skip the web dashboard
./install.sh --uninstall  # remove everything (binaries, images, config, PATH entry)
```

What it does:

1. **Checks host prerequisites** — verifies podman, pasta/passt, git, realpath, cgroups v2, sudo, python3 and a systemd user manager are available. Stops on missing required dependencies; warns on optional ones.
2. **Installs `ai-sandbox` and `ai-sandbox-build`** to `~/.local/bin/`.
3. **Copies Containerfiles and entrypoints** to `~/.local/share/ai-sandbox/`.
4. **Creates `~/.config/ai-sandbox/`** and a template `env` file (mode 600) if they don't exist.
5. **Builds container images** via `ai-sandbox-build all` (skip with `--no-build`).
6. **Builds the BPF loader** if the toolchain and kernel support are detected (clang, bpftool, libbpf, BTF, BPF LSM). This is optional — ai-sandbox works without it.
7. **Installs the [web UI](#web-ui)** (optional): `ai-sandbox-web`, its browser assets — downloaded once and verified against pinned SHA256 hashes — and a systemd user unit it offers to enable. A failed or mismatched download leaves the dashboard uninstalled with a warning rather than aborting the install.
8. **Checks PATH** — if `~/.local/bin` is not in your `$PATH`, offers to add it to your shell profile.

To uninstall, `--uninstall` stops and removes the web dashboard unit, offers to remove any `--web` sessions still running (they are the only containers that can outlive the shell that started them), removes `~/.local/bin/ai-sandbox`, `ai-sandbox-build`, `ai-sandbox-loader` and `ai-sandbox-web`, and `~/.local/share/ai-sandbox/`, then interactively offers to remove container images, `~/.config/ai-sandbox/`, and the PATH entry from your shell profile.

## Security Model

Every container is launched with the following hardening measures:

| Measure                       | Description                                                |
|-------------------------------|------------------------------------------------------------|
| `--userns=keep-id`            | UID mapping: files created in bind mount have your UID     |
| `--cap-drop=ALL`              | Removes all Linux capabilities                             |
| `--no-new-privileges`         | Prevents privilege escalation (setuid, etc.)               |
| `--read-only`                 | Container filesystem is read-only                          |
| `--pids-limit=512`            | Prevents fork bombs                                        |
| `--cpus` / `--memory`         | Limits CPU and RAM via cgroups v2 (default 2 CPU / 4g, see [Resource Limits](#resource-limits)) |
| `--network=pasta`             | Kernel-backed isolated network (fast, uses user namespaces)|
| `--tmpfs /tmp`                | Temporary writable area, destroyed at session end          |
| `--mount type=tmpfs,dst=/home/agent` | Agent home on tmpfs (mode 0755), destroyed at session end |
| Bind mount only `/workspace/<name>` | Agent sees ONLY the directories you passed in               |
| BPF LSM command blocker       | Blocks specific commands (e.g. git push) inside the container via eBPF |
| No published ports            | The web UI never publishes a container port; it reaches sessions via `podman exec` |
| Web sessions are opt-in        | Only containers started with `--web` are labelled and visible to the dashboard |
| Dashboard binds `127.0.0.1`    | Loopback only, behind a 256-bit bearer token in a 0600 file |

## Usage

```
ai-sandbox - Starts an AI agent in a sandboxed container

Usage: ai-sandbox <agent> [directory] [--dir path]... [-- extra args]
       ai-sandbox --build [target]
       ai-sandbox attach|stop <session>
       ai-sandbox list
       ai-sandbox web [options]

Available agents:
  claude        - Claude Code (Anthropic, direct API key)
  claude-vertex - Claude Code via Vertex AI (GCP auth)
  codex         - Codex CLI (OpenAI)
  cursor        - Cursor Agent CLI
  opencode      - opencode CLI on any OpenAI-compatible endpoint

Options:
      --dir [name=]<path> Mount an additional directory (repeatable), at /workspace/<name>
                          Defaults to the directory's basename; set <name>= on collisions
  -b, --block-cmd <b:a>   Block command inside container (repeatable, e.g. "git:push")
  -n, --network-off       Disable network (no API, local only)
  -d, --dns <server>      DNS server (default: 1.1.1.1, env: AI_SANDBOX_DNS)
      --cpus <n>          CPU limit (default: 2, env: AI_SANDBOX_CPUS)
      --memory <size>     RAM limit (default: 4g, env: AI_SANDBOX_MEMORY)
      --home-size <size>  Size of /home/agent tmpfs (default: 1g)
                          Units: b (bytes), k (kilobytes), m (megabytes), g (gigabytes)
      --build [target]    Build container images (all|base|claude|codex|cursor|opencode)
      --web               Run the agent inside a detachable session, visible to the
                          web dashboard (env: AI_SANDBOX_WEB=1)
      --web-name <name>   Session name for --web (default: <agent>-<dir>-<random>)
      --web-size <CxR>    Session geometry for --web when there is no terminal
                          to measure (default: 120x32)
      --non-interactive   Never prompt; fail instead (implied when stdin is not a TTY)
  -v, --verbose           Show the podman command being run
  -h, --help              Show this help

Session management (--web sessions only):
  attach <session>        Attach this terminal to a running session
  list                    List running web sessions
  stop <session>|--all    Stop a session
  web [options]           Run the web dashboard in the foreground

Options for opencode:
      --model <name>      Model to use (default: glm-5.2:cloud, env: AI_SANDBOX_OPENCODE_MODEL)
      --base-url <url>    API endpoint (default: https://ollama.com/v1, env: AI_SANDBOX_OPENCODE_BASE_URL)
      --no-api-key        Do not require AI_SANDBOX_OPENCODE_API_KEY (endpoints that ignore it)
```

## Multiple Repositories

The positional directory is the one the agent starts in. Every `--dir` mounts another directory alongside it, each at its own path under `/workspace/`:

```bash
ai-sandbox claude ~/projects/api --dir ~/projects/web --dir ~/projects/shared
```

```
/workspace/api      -> ~/projects/api      (working directory)
/workspace/web      -> ~/projects/web
/workspace/shared   -> ~/projects/shared
```

The mount name defaults to the directory's basename. If two directories share the same basename, ai-sandbox refuses to start rather than stacking them at one mount point — name one of them explicitly with `<name>=<path>`:

```bash
ai-sandbox claude ~/work/api --dir legacy-api=~/archive/api
# /workspace/api and /workspace/legacy-api
```

All mounts are read-write and each one is a separate bind mount, so the agent still sees nothing outside the directories you listed. Passing the same directory twice is a no-op.

## Resource Limits

CPU and RAM can be raised per run:

```bash
ai-sandbox claude --cpus 12 --memory 24g
```

Or persistently, in `~/.config/ai-sandbox/env`:

```bash
AI_SANDBOX_CPUS=12
AI_SANDBOX_MEMORY=24g
```

Precedence is: command-line flag > `~/.config/ai-sandbox/env` (or shell environment) > built-in
default (2 CPU, 4g).

The memory limit is always enforced. The CPU limit requires CFS bandwidth control in the kernel
(`CONFIG_CFS_BANDWIDTH=y`, which provides `cpu.max`) and, for rootless podman, the `cpu` controller
delegated to your user cgroup. When either is missing, `ai-sandbox` skips `--cpus` instead of
failing to start: the startup banner then reports `CPU unlimited (no cgroup quota)`, and an
explicit `--cpus` prints a warning.

## Customization

Edit the variables at the top of the `ai-sandbox` script:

```bash
MAX_CPUS_DEFAULT="2"   # Number of CPUs (override with --cpus / AI_SANDBOX_CPUS)
MAX_MEM_DEFAULT="4g"   # RAM limit (override with --memory / AI_SANDBOX_MEMORY)
MAX_PIDS="512"         # Process limit
TMPFS_TMP_SIZE="1g"    # /tmp size
TMPFS_HOME_SIZE="1g"   # /home/agent size (units: b, k, m, g)
NETWORK_MODE="pasta"   # "pasta" (fast) or "slirp4netns" (compatible)
DNS="1.1.1.1"          # Default DNS (override with --dns or AI_SANDBOX_DNS)
```

## Agent Details

### Claude Code

Installed via the [native installer](https://claude.ai/install.sh) (npm is deprecated and no longer used). Two authentication methods are supported:

- **API key**: set `ANTHROPIC_API_KEY` in your environment or in `~/.config/ai-sandbox/env`
- **OAuth (Pro/Max subscription)**: run `claude login` on the host first, then `~/.claude/` is automatically mounted into the container

### Claude Code via Vertex AI

Uses the same container image as Claude Code, but authenticates through Google Cloud (Vertex AI) instead of a direct Anthropic API key. Three variables must be set in `~/.config/ai-sandbox/env`:

```
CLAUDE_CODE_USE_VERTEX=1
CLOUD_ML_REGION=global
ANTHROPIC_VERTEX_PROJECT_ID=<your-gcp-project-id>
```

Additionally, `~/.config/gcloud/` must exist on the host with valid credentials (run `gcloud auth application-default login` beforehand). The directory is mounted read-only into the container.

Claude state is fully isolated from the personal `~/.claude/` and `~/.claude.json`:

- **`~/.config/ai-sandbox/claude-vertex/`** is mounted as `~/.claude` inside the container (settings, projects, cache)
- **`~/.config/ai-sandbox/claude-vertex.json`** is mounted as `~/.claude.json` (onboarding state)

Both are created automatically by `install.sh` (or on first run). The onboarding is done only once — subsequent runs reuse the persisted state. The host's personal `~/.claude/` and `~/.claude.json` are never touched.

Vertex variables can be defined in `~/.config/ai-sandbox/env` or exported in the shell — both work. They are passed to the container via `-e` from the current process environment.

### Codex

Installed via `npm install -g @openai/codex`. Two authentication methods are supported:

- **API key**: set `OPENAI_API_KEY` in your environment or in `~/.config/ai-sandbox/env`
- **OAuth (ChatGPT login)**: run `codex login` on the host first, then `~/.codex/` is automatically mounted into the container (contains `auth.json` and `config.toml`)

### Cursor Agent

Installed via the official `cursor.com/install` script. The installation is copied to `/opt/cursor-agent` at build time so that it survives the tmpfs mount on `/home/agent` at runtime. Authenticates through `CURSOR_API_KEY` or via `~/.config/cursor/` (bind-mounted read-write into the container). The `~/.config/cursor/` directory is created automatically by `install.sh` if it doesn't exist.

### opencode

Installed via `npm install -g opencode-ai`. The [opencode](https://opencode.ai) CLI is provider-agnostic: the entrypoint configures it with the `@ai-sdk/openai-compatible` provider, so it works against **any endpoint that speaks OpenAI-compatible `/v1/chat/completions`** — Ollama Cloud, Groq, Together, OpenRouter, vLLM, llama.cpp, LM Studio, and so on.

The default is **Ollama Cloud**, which needs no changes to the container's network stack: only outbound HTTPS, which `pasta` already provides.

Three settings control it, each configurable in `~/.config/ai-sandbox/env`, in the shell environment, or per run on the command line:

| Setting  | Env var                        | Flag           | Default                 |
| -------- | ------------------------------ | -------------- | ----------------------- |
| API key  | `AI_SANDBOX_OPENCODE_API_KEY`  | `--no-api-key` | *(required)*            |
| Model    | `AI_SANDBOX_OPENCODE_MODEL`    | `--model`      | `glm-5.2:cloud`         |
| Endpoint | `AI_SANDBOX_OPENCODE_BASE_URL` | `--base-url`   | `https://ollama.com/v1` |

These are read by ai-sandbox's own entrypoint, not by opencode, hence the `AI_SANDBOX_` prefix used elsewhere in the project. The `OPENCODE_*` namespace is deliberately avoided: it belongs to opencode itself (`OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, …).

Precedence is **CLI flag > env file > shell environment > built-in default**. (The env file is sourced with `set -a`, so it overrides variables already exported in the shell; the CLI flags are applied afterwards and always win.)

```bash
ai-sandbox opencode ~/projects/my-repo
ai-sandbox opencode . --model kimi-k2.6
ai-sandbox opencode . --base-url https://api.groq.com/openai/v1 --model llama-3.3-70b-versatile
```

For the default endpoint, get an API key at [ollama.com/settings/keys](https://ollama.com/settings/keys). Model names there follow the library tags (e.g. `glm-5.2:cloud`); going through a local Ollama daemon acting as a cloud proxy uses different tag conventions.

Two limits worth knowing: `@ai-sdk/openai-compatible` covers `/v1/chat/completions`, so a provider exposing only `/v1/responses` would need the `@ai-sdk/openai` package instead; and authentication is sent as a `Bearer` token, so endpoints wanting a different header (Azure OpenAI's `api-key`, for instance) are not supported as-is.

Session history and the downloaded provider package are persisted on the host under `~/.config/ai-sandbox/opencode/` (`share/`, `state/` and `cache/`), because `/home/agent` is a tmpfs and would otherwise be wiped on exit. These are bind-mounted on `/state` and symlinked into `~/.local/share`, `~/.local/state` and `~/.cache` by the entrypoint: mounting them directly under `/home/agent` would make podman create the parent directories as container root, leaving them unwritable by the `agent` user.

**Pointing at a service on the host:** `--base-url` accepts any endpoint, but `http://localhost:11434/v1` will *not* work — inside the container `localhost` is the container itself, not the host. Reaching a daemon running on the host additionally requires host gateway plumbing (and binding that daemon to something other than `127.0.0.1`, which exposes it beyond the sandbox). That is deliberately out of scope here; `--base-url` and `--no-api-key` are usable today for remote or proxied endpoints.

The [web UI](#web-ui) does not change this. It publishes no container port and adds no host gateway plumbing: the dashboard runs on the host and drives containers through `podman exec`, the same way a person at a terminal does. The container→host direction stays closed, and `test/test_webui.sh` asserts it from inside a running sandbox.

## Base Image

Built on **Fedora 44** and includes: Node.js, npm, Python 3.14 (default), Python 3.13, Python 3.12 (each with devel and libs — ready for `python3.XX -m venv`), pytest, ruff, yamllint, Git, curl, wget, ripgrep, fd-find, jq, yq, tree, Ansible, ansible-lint, ShellCheck, OpenShift client (`oc`), strace, poppler-utils (pdfinfo, pdftotext, pdfimages, etc.), mupdf (mutool — GUI binaries removed), pandoc, binutils (strings, objdump, nm, readelf, etc. — `as` and `ld` are removed for hardening), and standard GNU utilities (sed, gawk, grep, findutils, diffutils, patch, tar, gzip, unzip).

It also carries **zellij** (~44 MB), the terminal multiplexer behind [`--web`](#web-ui). It is fetched from the official GitHub release as a static musl binary, pinned by version and verified against a pinned SHA256 — the `no-web` variant, since zellij's own web server is not used. Nothing else in the image depends on it, and non-`--web` sessions never execute it.

The image is size-optimised: weak dependencies are skipped (`install_weak_deps=False`), documentation is excluded (`tsflags=nodocs`), mupdf's unused GUI dependencies (mesa, llvm-libs, X11) are removed after install, ELF binaries are stripped, and everything runs in a single layer.

## Notes

- **Git**: the script passes `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME`, `GIT_AUTHOR_EMAIL`, and `GIT_COMMITTER_EMAIL` from the host so that commits inside the container keep your identity.
- **Network**: by default uses `pasta` (faster than `slirp4netns`, uses the kernel's network stack via user namespaces). Change `NETWORK_MODE` to `slirp4netns` if `pasta` is not available. Pass `-n` to disable network entirely. To filter destinations with nftables, create rules on the host that match traffic from the container's network namespace.
- **Detaching**: only sessions started with `--web` survive their terminal closing — see [Web UI](#web-ui). Without it the agent is PID 1 in a foreground container, exactly as before.
- **Agent config persistence**: `/home/agent` is a tmpfs, so agent config (login, cache) is lost on each restart. For auth, use environment variables. If you want to persist config, add a dedicated volume:

```bash
-v "${HOME}/.cache/ai-sandbox/${AGENT}:/home/agent/.config:Z"
```

- **Claude**: if `~/.claude` exists on the host, it is bind-mounted into the container for OAuth session persistence.
- **Claude Vertex**: `~/.config/gcloud` is mounted read-only for GCP credentials. Uses dedicated `~/.config/ai-sandbox/claude-vertex/` and `claude-vertex.json` instead of the host's `~/.claude/` and `~/.claude.json`, ensuring full isolation between personal and vertex sessions.
- **Codex**: if `~/.codex` exists on the host, it is bind-mounted into the container for OAuth/cached login persistence.
- **Cursor**: if `~/.cursor` exists on the host, it is bind-mounted into the container so `cursor-agent` has access to its project state and config. `~/.config/cursor/` is also bind-mounted read-write for auth and configuration persistence.

## Command Blocking (BPF LSM)

You can optionally block specific commands inside the sandbox using eBPF programs that intercept `execve` calls within the container's cgroup. The `--block-cmd` (`-b`) flag is repeatable.

The format is `binary:arg1` where `arg1` is optional:

```bash
# Block git push (git with any other argument is allowed)
ai-sandbox claude ~/project --block-cmd "git:push"

# Block git entirely, regardless of arguments
ai-sandbox claude ~/project --block-cmd "git:"

# Block multiple commands
ai-sandbox cursor ~/project \
  --block-cmd "git:push" \
  --block-cmd "git:push --force" \
  --block-cmd "curl:" \
  --block-cmd "wget:"

# Combine with other options
ai-sandbox codex ~/project --block-cmd "rm:" --network-off
```

How blocking works depends on the rule type:

- **Binary-only rules** (`git:`, `curl:`) — blocked via the LSM hook *before* exec completes. The command is never executed (`-EPERM`).
- **Binary+arg rules** (`git:push`, `git:push --force`) — enforced via a tracepoint *after* exec, when argv is readable. The process is killed immediately (`SIGKILL`).

### Setup

This requires a kernel with `CONFIG_BPF_LSM=y` and `bpf` in the LSM list (`cat /sys/kernel/security/lsm`).

If you ran `./install.sh`, the BPF loader was built and installed automatically (provided the toolchain and kernel support were detected). To build it manually:

```bash
make -C bpf/
```

This compiles the loader and installs it to `~/.local/bin/ai-sandbox-loader`, where `ai-sandbox` expects to find it. You can override the install location with `make -C bpf/ LOADER_DIR=/other/path` and point the script to it via `AI_SANDBOX_BPF_LOADER=/other/path/ai-sandbox-loader`.

The BPF loader runs with `sudo` (required for loading BPF programs). The `ai-sandbox` wrapper handles this automatically when `--block-cmd` is passed. Blocking is scoped to the container's cgroup v2 — host processes are never affected.

See [bpf/README.md](bpf/README.md) for full details on kernel requirements, build dependencies, and how it works.

## Web UI

An optional dashboard that lists, starts and stops sandboxes, and gives you a browser terminal attached to the **same session** as your terminal — both are live read/write clients, and either can come and go without disturbing the other or the agent.

It is entirely opt-in. A sandbox is reachable from the browser **only** if it was started with `--web`; anything else is invisible to the web layer.

### Using it

```bash
# Start a detachable session and attach this terminal to it.
# Ctrl-o d detaches — the agent keeps running.
ai-sandbox --web claude ~/my-project

# From another terminal, or after closing the first one:
ai-sandbox list
ai-sandbox attach claude-my-project-a1b2
ai-sandbox stop claude-my-project-a1b2      # or: ai-sandbox stop --all

# The dashboard (installed by install.sh as a systemd user service):
xdg-open "http://127.0.0.1:8765/?t=$(cat ~/.config/ai-sandbox/web-token)"
```

Opening `http://127.0.0.1:8765/` without the `?t=` gives a form to paste the token into instead; either way the token is exchanged once for an `HttpOnly` session cookie and never appears in a URL again.

The dashboard starts sessions with the same parameters as the command line: agent, the working directory and any number of extra directories (one per line, each mounted at `/workspace/<name>` like `--dir`), an optional session name, CPUs, memory, network on/off, and `--block-cmd` rules one per line. It builds no `podman run` of its own — it invokes `ai-sandbox`, so every session is hardened identically however it was started.

Without `--web` nothing changes: the agent is PID 1 in a foreground container, zellij never runs, and the container carries no labels.

| Flag | Env var | Meaning |
|------|---------|---------|
| `--web` | `AI_SANDBOX_WEB=1` | Detachable session, visible to the dashboard |
| `--web-name <name>` | `AI_SANDBOX_SESSION` | Session name (default `<agent>-<dir>-<random>`; the directory part is filed down to letters, digits, `-` and `_`, so `~/my.repo` gives `claude-my-repo-…`) |
| `--web-size <CxR>` | — | Session geometry when there is no terminal to measure |
| — | `AI_SANDBOX_WEB_ADDR` / `AI_SANDBOX_WEB_PORT` | Dashboard bind address and port |
| — | `AI_SANDBOX_WEB_ROOTS` | Colon-separated roots a dashboard-started session may mount from (default `$HOME`) |

The session name is the single identifier throughout: it is the zellij session, the container name (`sandbox-<session>`), and the dashboard's id for it.

### How it fits together

```
 host                                            container (hardening unchanged)
 ─────────────────────────────────────────      ──────────────────────────────────
 browser ─HTTP/SSE─> ai-sandbox-web                     no published port, ever
 127.0.0.1:8765     (systemd --user)                     │
                       │                          PID 1: entrypoint.sh
                       ├ podman ps --filter label=…        └ ai-sandbox-supervise
                       ├ ai-sandbox … --web                      │ zellij session
                       └ podman exec -it <ctr> ────────>         ▼
                             zellij attach <s>            claude / codex / …
                                   ▲
 terminal ─ ai-sandbox attach <s> ─┘
```

`TERM` and `COLORTERM` are set on the container, not on the attach: zellij hands its panes the environment of the zellij server, which is container PID 1, so that is the only place an agent can learn it has a terminal at all — a `TERM` given to `podman exec … zellij attach` reaches the client and never the agent, which would then render in black and white for every viewer. `--web` passes the launching terminal's own `TERM` (the image's `xterm-256color` is the default for anything else), and refuses to pass on a useless one: a systemd user service has `TERM=dumb`, and handing that to an agent claims a terminal that cannot do colour.

The agent runs inside a detached [zellij](https://zellij.dev) session, which is what makes detaching safe: the terminal and the browser are both ordinary zellij clients, and closing either one leaves the agent untouched. Container PID 1 is a small supervisor that outlives every client and exits only when the agent does, at which point `--rm` removes the container.

### Security

The web layer adds no privileges to the sandboxes and no new paths into them.

- **No container port is published** and no host gateway plumbing is added. The dashboard reaches sessions through `podman exec`, exactly as you would from a shell. See the note under [opencode](#opencode) about host↔container networking; this keeps that promise.
- **Sessions are opt-in.** Only `--web` containers carry `ai-sandbox.*` labels. Every attach, stop and exec re-checks the label on the container itself rather than trusting a listing, so a session started without `--web` reports as *absent*, not as refused.
- **The dashboard never builds a `podman run` command.** It starts sessions by invoking `ai-sandbox`, so container hardening stays single-sourced and cannot be weakened from the browser.
- **The start API validates every field** and passes each as its own argv element — no shell is involved. Directories must resolve strictly below `AI_SANDBOX_WEB_ROOTS` (default `$HOME`), so a request cannot ask for a sandbox over `/`.
- **Hidden directories are neither offered nor accepted.** Being below `$HOME` is not enough to be safe to mount: `~/.ssh`, `~/.gnupg` and `~/.config/ai-sandbox` all are, and the last holds the dashboard's own token and the API-key file. Mounts are read-write, so a dot directory would hand a compromised agent the host. A dot component anywhere below the root is refused — from the terminal it still works, because there the person typing is the one choosing.
- **The Directory field completes as you type**, from `GET /api/dirs`, which lists the immediate children of the directory being typed in and never recurses: one `scandir` per request, whatever the size of the tree below, capped at 500 entries. It is bound by the same roots (browsing a root is allowed, mounting one is not), so it cannot be used to probe the filesystem. Matching ignores case as a typing convenience, but the paths offered are the exact names on disk — on a case-sensitive filesystem `~/Repos` and `~/repos` are two directories, and choosing between them is not the server's job.
- **Loopback only**, with a 256-bit bearer token generated on first start in `~/.config/ai-sandbox/web-token` (mode 0600, never mounted into a container, never passed as an environment variable). The bind address is refused if it is not loopback: there is no TLS here, so put a reverse proxy in front if you need remote access.
- Requests are checked for a `Host` we actually bound (a DNS-rebinding defence — note that it does *not* stop a process inside a container, which can send any `Host`; the token does), an `Origin` on the same loopback, and an `X-AI-Sandbox` header on anything state-changing. Browser assets are pinned by SHA256 and served from disk, so the page's `Content-Security-Policy` can be `default-src 'self'` with no CDN at runtime.
- The dashboard is served by Python's `http.server`, which upstream documents as not for production. That is acceptable here precisely because the socket is loopback-only, single-user and token-gated — do not widen it.
- `--block-cmd` rules can be given in the dashboard's start form, one per line, but the BPF loader needs `sudo` and a systemd user service has no terminal to prompt at. The host must therefore grant **passwordless** sudo for the loader; without it `ai-sandbox` refuses the start and the dashboard shows that error. Rules are validated against `<binary>:<argument>` before they are passed on.

### Screenshot and image paste

Pasting an image into the browser terminal uploads it into the session's `/tmp` and types the resulting path into the prompt, which is what the CLI agents accept. PNG, JPEG, GIF and WebP up to 10 MB; the type is confirmed by inspecting the file's magic bytes, and the filename is generated server-side. Ordinary text paste is untouched and stays bracketed.

### Terminal size with two clients

zellij sizes a shared session to its **smallest** attached client — measured against 0.45.1: a 200x50 client and a 100x30 one give a 100x29 session, and it springs back to 200x50 when the small client leaves. A client *larger* than the session shrinks nobody.

So the browser may **grow** the session freely, and that is what it does on attach: it adopts the geometry recorded on the container, then asks for its own window's grid. **Shrinking** is what would drag another client down, so a request for less than the browser's current size is refused with `409` while anyone else is attached; the browser then scales the rendered grid to fit the window instead.

The zoom control in the header changes the type size and asks the session for the grid that now fits — larger type, fewer columns, as in any terminal emulator. When the session cannot follow because another client is attached, the grid stays as it is and is painted at the chosen size, scrolling if it no longer fits.

Two consequences are worth knowing: if you resize your *terminal* while a browser is attached, zellij still reflows to the smaller of the two, and there is no fix for that at this layer; and a session's geometry is fixed when it is created, so `--web-size` (or the dashboard, which sends the browser's own grid) decides where it starts.

### The systemd user service

`install.sh` installs `~/.config/systemd/user/ai-sandbox-web.service` and offers to enable it.

```bash
systemctl --user status ai-sandbox-web
systemctl --user restart ai-sandbox-web
journalctl --user -u ai-sandbox-web -f
```

Two things to know:

- The unit deliberately sets `NoNewPrivileges=no`. Rootless podman execs the setuid helpers `newuidmap`/`newgidmap`, which `no_new_privs` blocks outright — "hardening" that line breaks every sandbox the dashboard starts.
- Without lingering, logging out stops your systemd user manager, and with it the dashboard *and* your running sessions. Enable it if you want sessions to survive logout:

  ```bash
  loginctl enable-linger "$USER"
  ```

If you have no systemd user manager, run the dashboard in the foreground instead:

```bash
ai-sandbox web            # or: ai-sandbox web --port 9000
```

### Tests

```bash
bash test/test_webui.sh   # no root required, unlike the BPF tests
```

## License

[GPLv3](LICENSE)
