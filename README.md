# AI Agent Sandbox

Rootless Podman containers to run AI coding agents (Claude Code, Codex, Cursor Agent) in isolation. Each agent runs in a hardened, read-only container with minimal capabilities, resource limits and an isolated network stack.

## Structure

```
ai-sandbox/
├── base/
│   └── Containerfile          # Base image (Fedora 43, Node.js, Python, Git, ripgrep, …)
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
├── test/
│   └── test_bpf_blocker.sh   # End-to-end tests for BPF command blocker
├── install.sh                 # Installer (and uninstaller) script
├── build.sh                   # Build script for images
├── ai-sandbox                 # Wrapper to start agents
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

# 2. Configure API keys (once)
mkdir -p ~/.config/ai-sandbox
cat > ~/.config/ai-sandbox/env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
CURSOR_API_KEY=...
EOF
chmod 600 ~/.config/ai-sandbox/env

# 3. Use it!
ai-sandbox claude ~/projects/my-repo
ai-sandbox codex  .
ai-sandbox cursor ~/projects/other -- chat "find bugs"
ai-sandbox claude                   # uses current directory
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
2. **Installs `ai-sandbox`** to `~/.local/bin/`.
3. **Builds container images** via `build.sh all` (skip with `--no-build`).
4. **Builds the BPF loader** if the toolchain and kernel support are detected (clang, bpftool, libbpf, BTF, BPF LSM). This is optional — ai-sandbox works without it.
5. **Checks PATH** — if `~/.local/bin` is not in your `$PATH`, offers to add it to your shell profile.

To uninstall, `--uninstall` removes `~/.local/bin/ai-sandbox`, `~/.local/bin/ai-sandbox-loader`, and interactively offers to remove container images, `~/.config/ai-sandbox/`, and the PATH entry from your shell profile.

## Security Model

Every container is launched with the following hardening measures:

| Measure                       | Description                                                |
|-------------------------------|------------------------------------------------------------|
| `--userns=keep-id`            | UID mapping: files created in bind mount have your UID     |
| `--cap-drop=ALL`              | Removes all Linux capabilities                             |
| `--no-new-privileges`         | Prevents privilege escalation (setuid, etc.)               |
| `--read-only`                 | Container filesystem is read-only                          |
| `--pids-limit=512`            | Prevents fork bombs                                        |
| `--cpus=2 --memory=4g`        | Limits CPU and RAM resources via cgroups v2                |
| `--network=pasta`             | Kernel-backed isolated network (fast, uses user namespaces)|
| `--tmpfs /tmp`                | Temporary writable area, destroyed at session end          |
| `--mount type=tmpfs,dst=/home/agent` | Agent home on tmpfs (mode 0755), destroyed at session end |
| Bind mount only `/workspace`  | Agent sees ONLY the project directory                      |
| BPF LSM command blocker       | Blocks specific commands (e.g. git push) inside the container via eBPF |

## Usage

```
ai-sandbox <agent> [directory] [-- extra args for the agent]

Agents:   claude | codex | cursor

Options:
  -b, --block-cmd <b:a>   Block command inside container (repeatable, e.g. "git:push")
  -n, --network-off       Disable network completely (--network=none)
  -d, --dns <server>      DNS server (default: 1.1.1.1, env: AI_SANDBOX_DNS)
  -v, --verbose           Show the podman command being run
  -h, --help              Show help
```

## Customization

Edit the variables at the top of the `ai-sandbox` script:

```bash
MAX_CPUS="2"           # Number of CPUs
MAX_MEM="4g"           # RAM limit
MAX_PIDS="512"         # Process limit
TMPFS_TMP_SIZE="1g"    # /tmp size
TMPFS_HOME_SIZE="512m" # /home/agent size
NETWORK_MODE="pasta"   # "pasta" (fast) or "slirp4netns" (compatible)
DNS="1.1.1.1"          # Default DNS (override with --dns or AI_SANDBOX_DNS)
```

## Agent Details

### Claude Code

Installed via the [native installer](https://claude.ai/install.sh) (npm is deprecated and no longer used). Two authentication methods are supported:

- **API key**: set `ANTHROPIC_API_KEY` in your environment or in `~/.config/ai-sandbox/env`
- **OAuth (Pro/Max subscription)**: run `claude login` on the host first, then `~/.claude/` is automatically mounted into the container

### Codex

Installed via `npm install -g @openai/codex`. Two authentication methods are supported:

- **API key**: set `OPENAI_API_KEY` in your environment or in `~/.config/ai-sandbox/env`
- **OAuth (ChatGPT login)**: run `codex login` on the host first, then `~/.codex/` is automatically mounted into the container (contains `auth.json` and `config.toml`)

### Cursor Agent

Installed via the official `cursor.com/install` script. The installation is copied to `/opt/cursor-agent` at build time so that it survives the tmpfs mount on `/home/agent` at runtime. Authenticates through `CURSOR_API_KEY` or via `~/.config/cursor/auth.json` (mounted read-only into the container).

## Base Image

Built on **Fedora 43** and includes: Node.js, npm, Python 3.14 (default), Python 3.13, Python 3.12 (each with devel and libs — ready for `python3.XX -m venv`), pytest, ruff, Git, curl, wget, ripgrep, fd-find, jq, yq, tree, Ansible, ansible-lint, ShellCheck, OpenShift client (`oc`), strace, binutils (strings, objdump, nm, readelf, etc. — `as` and `ld` are removed for hardening), and standard GNU utilities (sed, gawk, grep, findutils, diffutils, patch, tar, gzip, unzip).

## Notes

- **Git**: the script passes `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME`, `GIT_AUTHOR_EMAIL`, and `GIT_COMMITTER_EMAIL` from the host so that commits inside the container keep your identity.
- **Network**: by default uses `pasta` (faster than `slirp4netns`, uses the kernel's network stack via user namespaces). Change `NETWORK_MODE` to `slirp4netns` if `pasta` is not available. Pass `-n` to disable network entirely. To filter destinations with nftables, create rules on the host that match traffic from the container's network namespace.
- **Agent config persistence**: `/home/agent` is a tmpfs, so agent config (login, cache) is lost on each restart. For auth, use environment variables. If you want to persist config, add a dedicated volume:

```bash
-v "${HOME}/.cache/ai-sandbox/${AGENT}:/home/agent/.config:Z"
```

- **Claude**: if `~/.claude` exists on the host, it is bind-mounted into the container for OAuth session persistence.
- **Codex**: if `~/.codex` exists on the host, it is bind-mounted into the container for OAuth/cached login persistence.
- **Cursor**: if `~/.cursor` exists on the host, it is bind-mounted into the container so `cursor-agent` has access to its project state and config.

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
