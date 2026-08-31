# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Rootless Podman containers for running AI coding agents (Claude Code, Claude Code via Vertex AI, Codex, Cursor Agent, opencode) in isolation. Each agent runs in a hardened, read-only container with minimal capabilities, resource limits, and an isolated network stack. An optional eBPF LSM program can block specific commands (e.g., `git push`) inside the container. An optional web dashboard (`web/`) gives browser access to sessions started with `--web`.

## Build & Lint Commands

**Build container images (requires Podman):**
```bash
podman build --format docker --tag localhost/agent-base:latest --file base/Containerfile base/
podman build --format docker --tag localhost/agent-claude:latest --file claude-code/Containerfile claude-code/
podman build --format docker --tag localhost/agent-codex:latest --file codex/Containerfile codex/
podman build --format docker --tag localhost/agent-cursor:latest --file cursor-agent/Containerfile cursor-agent/
podman build --format docker --tag localhost/agent-opencode:latest --file opencode/Containerfile opencode/
```

**Lint:**
```bash
# Shell scripts (CI uses ShellCheck)
shellcheck ai-sandbox ai-sandbox-build install.sh base/ai-sandbox-supervise claude-code/entrypoint.sh codex/entrypoint.sh cursor-agent/entrypoint.sh opencode/entrypoint.sh test/test_bpf_blocker.sh test/test_webui.sh

# Web dashboard (Python; CI runs py_compile + ruff)
python3 -m py_compile web/ai-sandbox-web && ruff check web/ai-sandbox-web

# Containerfiles (CI uses Hadolint)
hadolint base/Containerfile claude-code/Containerfile codex/Containerfile cursor-agent/Containerfile opencode/Containerfile
```

**BPF loader (optional, requires clang, bpftool, libbpf, BTF kernel):**
```bash
make -C bpf/                  # builds loader, installs to ~/.local/bin/ai-sandbox-loader
make -C bpf/ clean
```

**Tests (BPF blocker e2e, requires root + built images + BPF kernel support):**
```bash
sudo bash test/test_bpf_blocker.sh
```

**Tests (web UI e2e, requires built images + python3; NO root):**
```bash
bash test/test_webui.sh
```

## Architecture

There are three main Bash scripts, one Python script, and a BPF subsystem:

- **`ai-sandbox`** — the user-facing wrapper. Parses arguments, validates auth/images, constructs a `podman run` command with all security flags, and optionally starts the BPF loader for `--block-cmd` rules. Three execution modes: normal (`exec podman run`), BPF-blocking (starts the container in the background, resolves its cgroup, launches the loader, then `podman attach`), and web (`--web`: starts detached with `--rm`, then attaches with `podman exec ... zellij attach`, so detaching does not kill the agent). Also dispatches the `attach`/`list`/`stop`/`web` subcommands.

- **`ai-sandbox-build`** — standalone build script. Reads Containerfiles from `~/.local/share/ai-sandbox/` (installed by `install.sh`). Builds base first, then agent images on top.

- **`install.sh`** — installer/uninstaller. Checks prerequisites, copies scripts and Containerfiles, creates config dirs, builds images, optionally builds BPF loader, handles PATH setup. `--uninstall` reverses everything interactively.

- **`web/ai-sandbox-web`** — the web dashboard. The only Python in the repo, and standard-library only by policy: this project installs no runtime dependencies. It lists/starts/stops `--web` sessions and serves a browser terminal over SSE (output) plus POST (input), driving containers with `podman exec`.

- **`base/ai-sandbox-supervise`** — entrypoint shim in every agent image. A transparent `exec "$@"` unless `AI_SANDBOX_WEB=1`, in which case it starts the agent in a detached zellij session and becomes the process that keeps the container alive.

- **`bpf/`** — eBPF LSM command blocker. `block_commands.bpf.c` hooks `bprm_check_security` (binary-only rules, blocks before exec) and uses a tracepoint (binary+arg rules, kills after exec). `loader.c` is the userspace loader using libbpf skeletons. Blocking is scoped to a container's cgroup v2.

**Container image hierarchy:** `base/Containerfile` (Fedora 44 + tooling) → agent-specific Containerfiles (`claude-code/`, `codex/`, `cursor-agent/`, `opencode/`) each `FROM localhost/agent-base:latest`. Nothing an agent needs at runtime may live under `/home/agent`, which is replaced by a tmpfs: installers that write there (`claude-code/`, `cursor-agent/`) are copied to `/opt` at build time, while npm global installs (`codex/`, `opencode/`) already land outside it.

## CI

Two GitHub Actions workflows on push/PR to `main`:
- **Lint** (`lint.yml`): ShellCheck on all `.sh`/`.bash` files + `ai-sandbox` + `base/ai-sandbox-supervise`; `py_compile` and `ruff` on `web/ai-sandbox-web` (it is Python and must stay out of the ShellCheck sweep); Hadolint on all Containerfiles
- **Build** (`build.yml`): Builds all images with Podman, runs smoke tests (`--version` on each agent image, `zellij --version` in the base image, and `ai-sandbox-supervise` passthrough)

## Git Policy

Do NOT create commits automatically. All commits must be reviewed and approved by the user before being made.

## Conventions

- All scripts use `set -euo pipefail` and `#!/bin/bash`.
- Hadolint ignores are in `.hadolint.yaml`: DL3041 (dnf version pinning), DL3007 (FROM :latest for local base), DL3016 (npm version pinning). These are intentional for a rolling-release base.
- Container images are tagged `localhost/agent-{base,claude,codex,cursor,opencode}:latest`.
- `claude-vertex` shares the `agent-claude` image; there is no separate build target.
- Host directories that must persist are bind-mounted **outside** `/home/agent` (e.g. `opencode/` uses `/state`) and symlinked into place by the entrypoint. Mounting them directly under `/home/agent` makes podman create the parent directories as container root, which the `agent` user cannot write into.
- The `agent` user (UID 1000) runs inside containers. `--userns=keep-id:uid=1000,gid=1000` maps host UID to container UID 1000.
- When adding or removing packages in `base/Containerfile`, always update the package list in the **Base Image** section of `README.md` to match.
- Binaries downloaded into an image, and browser assets downloaded by `install.sh`, are pinned by version **and** verified against a pinned SHA256. Do not add an unverified download.
- Podman labels live under the `ai-sandbox.*` namespace. Any operation on a caller-supplied session name must re-verify `ai-sandbox.web=1` on the container itself (`resolve_web_container` in `ai-sandbox`, `resolve_container` in `ai-sandbox-web`) rather than trusting a listing — that is what makes non-`--web` sessions invisible rather than merely refused.
- **No container port is ever published.** The web layer reaches containers only through `podman exec`; `README.md` records the decision to keep host↔container network plumbing out of scope, and `test/test_webui.sh` enforces it.
- Anything that both container PID 1 and `podman exec` must agree on (e.g. `ZELLIJ_SOCKET_DIR`) belongs in the Containerfile as `ENV`, not as an entrypoint export: `podman exec` inherits `Config.Env`, not the entrypoint's runtime exports.
- Never poll `zellij list-sessions` in a wait loop. Every zellij client connection resets the session's idle teardown, so the poll keeps alive the session it is waiting to see end; watch the session socket instead.
