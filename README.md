# AI Agent Sandbox

Rootless Podman containers to run AI coding agents (Claude Code, Codex, Cursor Agent) in isolation. Each agent runs in a hardened, read-only container with minimal capabilities, resource limits and an isolated network stack.

## Structure

```
ai-sandbox/
├── base/
│   └── Containerfile          # Base image (Fedora 43, Node.js, Python, Git, ripgrep, …)
├── claude-code/
│   └── Containerfile          # Claude Code (native installer + npm fallback)
├── codex/
│   └── Containerfile          # OpenAI Codex CLI
├── cursor-agent/
│   └── Containerfile          # Cursor Agent CLI (installed to /opt to survive tmpfs)
├── build.sh                   # Build script for images
├── ai-sandbox                 # Wrapper to start agents
├── LICENSE                    # GPLv3
└── README.md
```

## Requirements

- [Podman](https://podman.io/) (rootless) — tested with v4+
- cgroups v2 enabled (default on recent Fedora, Arch, Debian 12+, Ubuntu 24.04+)

## Quick Start

```bash
# 1. Build all images (or just one: ./build.sh claude)
chmod +x build.sh
./build.sh all

# 2. Configure API keys (once)
mkdir -p ~/.config/ai-sandbox
cat > ~/.config/ai-sandbox/env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
CURSOR_API_KEY=...
EOF
chmod 600 ~/.config/ai-sandbox/env

# 3. Install the wrapper
chmod +x ai-sandbox
cp ai-sandbox ~/bin/        # or ~/.local/bin/

# 4. Use it!
ai-sandbox claude ~/projects/my-repo
ai-sandbox codex  .
ai-sandbox cursor ~/projects/other -- chat "find bugs"
ai-sandbox claude                   # uses current directory
```

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

## Usage

```
ai-sandbox <agent> [directory] [-- extra args for the agent]

Agents:   claude | codex | cursor

Options:
  -n, --network-off   Disable network completely (--network=none)
  -v, --verbose        Show the podman command being run
  -h, --help           Show help
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
DNS="1.1.1.1"          # Explicit DNS server
```

## Agent Details

### Claude Code

Installed via the [native installer](https://claude.ai/install.sh) (npm is deprecated and no longer used). Two authentication methods are supported:

- **API key**: set `ANTHROPIC_API_KEY` in your environment or in `~/.config/ai-sandbox/env`
- **OAuth (Pro/Max subscription)**: run `claude login` on the host first, then `~/.claude/` is automatically mounted into the container

### Codex

Installed via `npm install -g @openai/codex`. Authenticates through `OPENAI_API_KEY`.

### Cursor Agent

Installed via the official `cursor.com/install` script. The installation is copied to `/opt/cursor-agent` at build time so that it survives the tmpfs mount on `/home/agent` at runtime. Authenticates through `CURSOR_API_KEY` or via `~/.config/cursor/auth.json` (mounted read-only into the container).

## Base Image

Built on **Fedora 43** and includes: Node.js, npm, Python 3, pip, Git, curl, wget, ripgrep, fd-find, jq, yq, tree, Ansible, ansible-lint, ShellCheck, OpenShift client (`oc`), strace, and standard GNU utilities (sed, gawk, grep, findutils, diffutils, patch, tar, gzip, unzip).

## Notes

- **Git**: the script passes `GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME`, `GIT_AUTHOR_EMAIL`, and `GIT_COMMITTER_EMAIL` from the host so that commits inside the container keep your identity.
- **Network**: by default uses `pasta` (faster than `slirp4netns`, uses the kernel's network stack via user namespaces). Change `NETWORK_MODE` to `slirp4netns` if `pasta` is not available. Pass `-n` to disable network entirely. To filter destinations with nftables, create rules on the host that match traffic from the container's network namespace.
- **Agent config persistence**: `/home/agent` is a tmpfs, so agent config (login, cache) is lost on each restart. For auth, use environment variables. If you want to persist config, add a dedicated volume:

```bash
-v "${HOME}/.cache/ai-sandbox/${AGENT}:/home/agent/.config:Z"
```

- **Claude**: if `~/.claude` exists on the host, it is bind-mounted into the container for OAuth session persistence.
- **Cursor**: if `~/.cursor` exists on the host, it is bind-mounted into the container so `cursor-agent` has access to its project state and config.

## License

[GPLv3](LICENSE)
