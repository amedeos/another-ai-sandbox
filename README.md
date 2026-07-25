# AI Agent Sandbox

Rootless Podman containers to run AI coding agents (Claude Code, Claude Code via Vertex AI, Codex, Cursor Agent, opencode) in isolation. Each agent runs in a hardened, read-only container with minimal capabilities, resource limits and an isolated network stack.

## Structure

```
ai-sandbox/
├── base/
│   └── Containerfile          # Base image (Fedora 44, Node.js, Python, Git, ripgrep, …)
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
│   └── Containerfile          # Cursor Agent CLI (installed to /opt to survive tmpfs)
├── opencode/
│   ├── Containerfile          # opencode CLI (any OpenAI-compatible endpoint)
│   └── entrypoint.sh          # Generates opencode.json from AI_SANDBOX_OPENCODE_*
├── test/
│   └── test_bpf_blocker.sh   # End-to-end tests for BPF command blocker
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
```

## Install

The `install.sh` script handles the full setup:

```bash
./install.sh              # full install: prerequisites check, images, BPF (if possible)
./install.sh --no-build   # install the script only, skip container image build
./install.sh --uninstall  # remove everything (binaries, images, config, PATH entry)
```

What it does:

1. **Checks host prerequisites** — verifies podman, pasta/passt, git, realpath, cgroups v2, and sudo are available. Stops on missing required dependencies; warns on optional ones.
2. **Installs `ai-sandbox` and `ai-sandbox-build`** to `~/.local/bin/`.
3. **Copies Containerfiles and entrypoints** to `~/.local/share/ai-sandbox/`.
4. **Creates `~/.config/ai-sandbox/`** and a template `env` file (mode 600) if they don't exist.
5. **Builds container images** via `ai-sandbox-build all` (skip with `--no-build`).
6. **Builds the BPF loader** if the toolchain and kernel support are detected (clang, bpftool, libbpf, BTF, BPF LSM). This is optional — ai-sandbox works without it.
7. **Checks PATH** — if `~/.local/bin` is not in your `$PATH`, offers to add it to your shell profile.

To uninstall, `--uninstall` removes `~/.local/bin/ai-sandbox`, `~/.local/bin/ai-sandbox-build`, `~/.local/bin/ai-sandbox-loader`, and `~/.local/share/ai-sandbox/`, then interactively offers to remove container images, `~/.config/ai-sandbox/`, and the PATH entry from your shell profile.

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
| Bind mount only `/workspace/<project-name>` | Agent sees ONLY the project directory                      |
| BPF LSM command blocker       | Blocks specific commands (e.g. git push) inside the container via eBPF |

## Usage

```
ai-sandbox <agent> [directory] [-- extra args for the agent]
ai-sandbox --build [all|base|claude|codex|cursor|opencode]

Agents:   claude | claude-vertex | codex | cursor | opencode

Options:
  -b, --block-cmd <b:a>   Block command inside container (repeatable, e.g. "git:push")
  -n, --network-off       Disable network completely (--network=none)
  -d, --dns <server>      DNS server (default: 1.1.1.1, env: AI_SANDBOX_DNS)
      --cpus <n>           CPU limit (default: 2, env: AI_SANDBOX_CPUS)
      --memory <size>      RAM limit (default: 4g, env: AI_SANDBOX_MEMORY)
      --home-size <size>   Size of /home/agent tmpfs (default: 1g, units: b, k, m, g)
      --build [target]     Build container images (all|base|claude|codex|cursor|opencode)
  -v, --verbose           Show the podman command being run
  -h, --help              Show help

Options for opencode:
      --model <name>      Model to use (default: glm-5.2:cloud, env: AI_SANDBOX_OPENCODE_MODEL)
      --base-url <url>    API endpoint (default: https://ollama.com/v1, env: AI_SANDBOX_OPENCODE_BASE_URL)
      --no-api-key        Do not require AI_SANDBOX_OPENCODE_API_KEY (endpoints that ignore it)
```

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

## Base Image

Built on **Fedora 44** and includes: Node.js, npm, Python 3.14 (default), Python 3.13, Python 3.12 (each with devel and libs — ready for `python3.XX -m venv`), pytest, ruff, yamllint, Git, curl, wget, ripgrep, fd-find, jq, yq, tree, Ansible, ansible-lint, ShellCheck, OpenShift client (`oc`), strace, poppler-utils (pdfinfo, pdftotext, pdfimages, etc.), mupdf (mutool — GUI binaries removed), pandoc, binutils (strings, objdump, nm, readelf, etc. — `as` and `ld` are removed for hardening), and standard GNU utilities (sed, gawk, grep, findutils, diffutils, patch, tar, gzip, unzip).

The image is size-optimised: weak dependencies are skipped (`install_weak_deps=False`), documentation is excluded (`tsflags=nodocs`), mupdf's unused GUI dependencies (mesa, llvm-libs, X11) are removed after install, ELF binaries are stripped, and everything runs in a single layer.

## Notes

- **Git**: the script passes `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME`, `GIT_AUTHOR_EMAIL`, and `GIT_COMMITTER_EMAIL` from the host so that commits inside the container keep your identity.
- **Network**: by default uses `pasta` (faster than `slirp4netns`, uses the kernel's network stack via user namespaces). Change `NETWORK_MODE` to `slirp4netns` if `pasta` is not available. Pass `-n` to disable network entirely. To filter destinations with nftables, create rules on the host that match traffic from the container's network namespace.
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

## License

[GPLv3](LICENSE)
