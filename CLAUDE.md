# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Rootless Podman containers for running AI coding agents (Claude Code, Claude Code via Vertex AI, Codex, Cursor Agent) in isolation. Each agent runs in a hardened, read-only container with minimal capabilities, resource limits, and an isolated network stack. An optional eBPF LSM program can block specific commands (e.g., `git push`) inside the container.

## Build & Lint Commands

**Build container images (requires Podman):**
```bash
podman build --format docker --tag localhost/agent-base:latest --file base/Containerfile base/
podman build --format docker --tag localhost/agent-claude:latest --file claude-code/Containerfile claude-code/
podman build --format docker --tag localhost/agent-codex:latest --file codex/Containerfile codex/
podman build --format docker --tag localhost/agent-cursor:latest --file cursor-agent/Containerfile cursor-agent/
```

**Lint:**
```bash
# Shell scripts (CI uses ShellCheck)
shellcheck ai-sandbox ai-sandbox-build install.sh claude-code/entrypoint.sh codex/entrypoint.sh test/test_bpf_blocker.sh

# Containerfiles (CI uses Hadolint)
hadolint base/Containerfile claude-code/Containerfile codex/Containerfile cursor-agent/Containerfile
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

## Architecture

There are three main scripts (all Bash) and a BPF subsystem:

- **`ai-sandbox`** — the user-facing wrapper. Parses arguments, validates auth/images, constructs a `podman run` command with all security flags, and optionally starts the BPF loader for `--block-cmd` rules. Two execution modes: normal (`exec podman run`) and BPF-blocking (starts container in background, resolves its cgroup, launches loader, then `podman attach`).

- **`ai-sandbox-build`** — standalone build script. Reads Containerfiles from `~/.local/share/ai-sandbox/` (installed by `install.sh`). Builds base first, then agent images on top.

- **`install.sh`** — installer/uninstaller. Checks prerequisites, copies scripts and Containerfiles, creates config dirs, builds images, optionally builds BPF loader, handles PATH setup. `--uninstall` reverses everything interactively.

- **`bpf/`** — eBPF LSM command blocker. `block_commands.bpf.c` hooks `bprm_check_security` (binary-only rules, blocks before exec) and uses a tracepoint (binary+arg rules, kills after exec). `loader.c` is the userspace loader using libbpf skeletons. Blocking is scoped to a container's cgroup v2.

**Container image hierarchy:** `base/Containerfile` (Fedora 44 + tooling) → agent-specific Containerfiles (`claude-code/`, `codex/`, `cursor-agent/`) each `FROM localhost/agent-base:latest`. Agent installs are moved to `/opt` at build time so they survive the tmpfs on `/home/agent` at runtime.

## CI

Two GitHub Actions workflows on push/PR to `main`:
- **Lint** (`lint.yml`): ShellCheck on all `.sh`/`.bash` files + `ai-sandbox`; Hadolint on all Containerfiles
- **Build** (`build.yml`): Builds all images with Podman, runs smoke tests (`--version` on each agent image)

## Git Policy

Do NOT create commits automatically. All commits must be reviewed and approved by the user before being made.

## Conventions

- All scripts use `set -euo pipefail` and `#!/bin/bash`.
- Hadolint ignores are in `.hadolint.yaml`: DL3041 (dnf version pinning), DL3007 (FROM :latest for local base), DL3016 (npm version pinning). These are intentional for a rolling-release base.
- Container images are tagged `localhost/agent-{base,claude,codex,cursor}:latest`.
- `claude-vertex` shares the `agent-claude` image; there is no separate build target.
- The `agent` user (UID 1000) runs inside containers. `--userns=keep-id:uid=1000,gid=1000` maps host UID to container UID 1000.
- When adding or removing packages in `base/Containerfile`, always update the package list in the **Base Image** section of `README.md` to match.
