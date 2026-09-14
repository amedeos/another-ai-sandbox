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
- Anything that both container PID 1 and `podman exec` must agree on (e.g. `ZELLIJ_SOCKET_DIR`) belongs in the Containerfile as `ENV`, not as an entrypoint export: `podman exec` inherits `Config.Env`, not the entrypoint's runtime exports. The same applies to anything the *agent* must see: zellij gives its panes the environment of the zellij server, i.e. of container PID 1, so `TERM` reaches the agent only through `podman run` (`-e`, or the image's `ENV`). A `TERM` passed to `podman exec ... zellij attach` configures the client and never the agent — verified: a pane whose server had no `TERM` has none either, and the agent then renders in black and white.
- Never poll `zellij list-sessions` in a wait loop. Every zellij client connection resets the session's idle teardown, so the poll keeps alive the session it is waiting to see end; watch the session socket instead.
- Always check the exit status of a `podman` call. A bad `--format` template makes podman fail the whole invocation, which an unchecked caller reads as "no containers" rather than as an error. Prefer `--format json` for listings (`list_sessions` in `ai-sandbox-web`); where a template is used, remember its fields are Go **struct** names, not the JSON keys of the same output — the container id is `{{.ID}}`, and `{{.Id}}` is a template error.
- `--web` sessions start in zellij's **locked** mode, with `clear-defaults` on the locked block and only `Alt g` bound (`base/zellij.kdl`). Do not add keybindings and do not restore `default_mode "normal"`: zellij's stock bindings claim Ctrl+G/Q/P/N/S/O/T/H/B and most Alt keys before the pane sees them, and the agents bind several of those themselves (Claude Code: Ctrl+G, Ctrl+O, Ctrl+T, Ctrl+B, Ctrl+R). `clear-defaults` is load-bearing, because stock locked mode reserves Ctrl+G as its way out, and zellij's `Quit` is unbound in every mode: `Ctrl+Q` sits one key from the `Ctrl+O` of the detach chord, and `--rm` makes a quit destructive. The detach chord is therefore `Alt-g` then `Ctrl-o d`, in `README.md` and in `detach_hint` (one function, printed by both attach paths).
- Browser image paste has **two routes, and both are needed** (`web/static/app.js`). xterm.js encodes Ctrl+V as `^V` and cancels the DOM event, so `attachCustomKeyEventHandler` hands that key back to the browser — match it by `keyCode`, as xterm does, or the two decisions drift apart on a non-Latin layout. The paste event is enough for Firefox; Chromium hands the page no usable image on any gesture (its Ctrl+Shift+V is *paste as plain text*), so both gestures also arm `navigator.clipboard.read()`, which is available only because the dashboard is loopback-only and therefore a secure context. Read the event's `items` as well as its `files`, synchronously — a `DataTransferItemList` is emptied when the handler returns — and keep the listener in the **capture** phase on `#term`, registered once at module scope: xterm's own paste listeners are on the textarea and its root element and would otherwise type the image's `text/plain` sibling at the prompt, and a per-attach listener stacks one upload per Back/Attach cycle. The two routes arbitrate through one gesture record (`armPaste`/`claimPaste`), which *both* must claim before acting, **plus** a `PASTE_SETTLE_MS` window after any delivery: the record alone cannot tell a new paste from the one just served arriving again — the listener sees no gesture in flight either way — and without the window a single Ctrl+V delivered twice in both engines (Gecko dispatches a second paste event per keystroke; in Chromium the clipboard read resolves first). The listener therefore cancels every paste that lands on `#term` and routes text through `term.paste()` itself: one path per gesture is what makes a duplicate recognisable. **Arm the gesture synchronously in the keydown handler**, never inside the timer callback — the paste event lands ~2 ms after the keystroke, so a gesture that only comes into being at +200 ms leaves that event to arm one of its own, and two gestures for one press is two deliveries (the defect that cost several rounds; the timeline that found it is the pattern to reach for again). `sendImage` keeps a last-resort guard on identical byte counts within `PASTE_DUPLICATE_MS`, because the agent must never be handed two paths for one image.
- Nothing in `test/test_webui.sh` can fire a DOM `paste` event, so the browser half of paste is manual: check it in **both** Chromium and Firefox. Keyboard delivery, by contrast, is covered end to end (`test_ctrl_keys_reach_the_pane` runs `cat -v` in the pane and asserts on the bytes that arrive).
