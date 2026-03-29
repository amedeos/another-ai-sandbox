# AI Agent Sandbox

Rootless Podman container to run AI coding agents (Claude Code, Codex, Cursor Agent) in isolation.

## Structure

```
ai-sandbox/
├── base/
│   └── Containerfile          # Base image with Node.js, Python, Git
├── claude-code/
│   └── Containerfile          # Claude Code (native installer + npm fallback)
├── codex/
│   └── Containerfile          # OpenAI Codex CLI
├── cursor-agent/
│   └── Containerfile          # Cursor Agent CLI
├── build.sh                   # Build script for images
├── ai-sandbox                 # Wrapper to start agents
└── README.md
```

## Quick Start

```bash
# 1. Build all images
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
```

## Applied Security

| Measure                       | Description                                                |
|-------------------------------|------------------------------------------------------------|
| `--userns=keep-id`            | UID mapping: files created in bind mount have your UID     |
| `--cap-drop=ALL`              | Removes all Linux capabilities                             |
| `--no-new-privileges`         | Prevents privilege escalation (setuid, etc.)               |
| `--read-only`                 | Container filesystem is read-only                          |
| `--pids-limit=512`            | Prevents fork bombs                                        |
| `--cpus=2 --memory=4g`        | Limits CPU and RAM resources via cgroups v2                |
| `--network=slirp4netns`       | Userspace network stack, isolated from host                |
| `--tmpfs /tmp` and `/home`    | Temporary writable areas, destroyed at session end         |
| Bind mount only `/workspace`  | Agent sees ONLY the project directory                      |

## Options

```
ai-sandbox <agent> [directory] [-- extra args for the agent]

Agent:   claude | codex | cursor
Options: -n/--network-off  Disable network completely
         -v/--verbose      Show the podman command
         -h/--help         Help
```

## Customization

Edit the variables at the top of the `ai-sandbox` script:

```bash
MAX_CPUS="2"           # Number of CPUs
MAX_MEM="4g"           # RAM limit
MAX_PIDS="512"         # Process limit
TMPFS_TMP_SIZE="1g"    # /tmp size
TMPFS_HOME_SIZE="512m" # /home/agent size
```

## Notes

- **Git**: the script passes `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` from the host for commits.
- **Network**: by default uses `slirp4netns`. To filter destinations with nftables, create rules
  on the host that match traffic from the container's network namespace.
- **Agent config persistence**: `/home/agent` is a tmpfs, so agent config
  (login, cache) is lost on each restart. For auth, use environment variables.
  If you want to persist config, add a dedicated volume:
  ```bash
  -v "${HOME}/.cache/ai-sandbox/${AGENT}:/home/agent/.config:Z"
  ```
