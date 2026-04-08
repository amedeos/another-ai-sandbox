# BPF LSM Command Blocker

## Overview

BPF LSM-based command blocker that prevents execution of specified commands inside containers. It uses two hooks — an LSM hook and a tracepoint — to cover both binary-only and binary+argument rules. Enforcement is scoped to a single cgroup v2, so blocking only applies to the target container; host processes and other containers are never affected. Blocked commands are configured at runtime via the userspace loader — no recompilation needed.

## Files

| File | Description |
|------|-------------|
| `block_commands.bpf.c` | BPF programs: LSM hook (`bprm_check_security`) and tracepoint (`sched_process_exec`) |
| `block_commands.h` | Shared `blocked_cmd_key` struct used by both BPF and userspace |
| `config.h` | Compile-time limits: `MAX_BIN_LEN`, `MAX_ARG_LEN`, `MAX_BLOCKED_CMDS` |
| `loader.c` | Userspace loader: loads BPF, populates maps, attaches hooks, handles signals |
| `Makefile` | Build system: generates `vmlinux.h`, compiles BPF object, generates skeleton, builds loader |
| `vmlinux.h` | *(generated)* Kernel type definitions dumped from `/sys/kernel/btf/vmlinux` |
| `block_commands.bpf.o` | *(generated)* Compiled BPF object |
| `block_commands.skel.h` | *(generated)* libbpf skeleton header |
| `loader` | *(generated)* Compiled userspace loader binary |

## Kernel Requirements

The following kernel options must be enabled:

```
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_LSM=y
CONFIG_DEBUG_INFO_BTF=y
```

The kernel command line (or `CONFIG_LSM`) must include `bpf` in the LSM list. Verify with:

```bash
cat /sys/kernel/security/lsm
# Should contain "bpf" in the comma-separated list
```

Fedora 43+ and recent Arch kernels have this enabled by default. On Gentoo, enable `CONFIG_BPF_LSM` and add `bpf` to `CONFIG_LSM` in your kernel config.

## Build Dependencies

```
Fedora:        dnf install clang llvm libbpf-devel bpftool elfutils-libelf-devel zlib-devel
Debian/Ubuntu: apt install clang llvm libbpf-dev linux-tools-common libelf-dev zlib1g-dev
Gentoo:        emerge -av sys-devel/clang sys-devel/llvm dev-libs/libbpf sys-apps/bpftool dev-libs/elfutils sys-libs/zlib
```

On Debian/Ubuntu, `bpftool` is provided by `linux-tools-common` (or `linux-tools-$(uname -r)` on some versions).

## Build

If you ran `./install.sh` from the project root, the BPF loader was built and installed automatically (provided the toolchain and kernel support were detected). To build manually:

```bash
cd bpf/
make
```

This compiles the BPF program and the userspace loader, then installs the loader to `~/.local/bin/ai-sandbox-loader`.

To clean build artifacts and the installed binary:

```bash
make clean
```

### Makefile Variables

The following variables can be overridden on the command line:

| Variable | Default | Description |
|----------|---------|-------------|
| `LOADER_DIR` | `~/.local/bin` | Where the loader binary is installed |
| `CLANG` | `clang` | C compiler for BPF programs |
| `CC` | `gcc` | C compiler for the userspace loader |
| `BPFTOOL` | `bpftool` | Tool for BTF dump and skeleton generation |
| `VMLINUX` | `/sys/kernel/btf/vmlinux` | Path to kernel BTF data |

Example:

```bash
make LOADER_DIR=/usr/local/bin CC=clang
```

## Usage

### Loader CLI Options

```
Usage: loader [OPTIONS]

Options:
  -c, --cgroup <path>       cgroup v2 path of target container (required)
  -b, --block <bin:arg1>    command to block (repeatable, at least one required)
  -V, --verbose             enable verbose output
  -h, --help                show help
```

### Block Rule Format

The `--block` argument uses the format `binary:arg1` where the colon separator is mandatory:

| Rule | Meaning | Enforcement |
|------|---------|-------------|
| `git:push` | Block `git` only when the first argument is `push` | Tracepoint (post-exec `SIGKILL`) |
| `git:push --force` | Block `git` when first arg is `push --force` | Tracepoint (post-exec `SIGKILL`) |
| `git:` | Block `git` regardless of arguments | LSM hook (pre-exec `-EPERM`) |
| `curl:` | Block `curl` entirely | LSM hook (pre-exec `-EPERM`) |

The binary name is matched against the **basename** of the executed path (e.g. `/usr/bin/git` matches `git`).

### Examples

```bash
# Standalone usage (requires sudo)
sudo ./loader --cgroup /sys/fs/cgroup/.../libpod-XXX.scope \
              --block "git:push" \
              --block "git:push --force" \
              --verbose

# Via ai-sandbox wrapper (sudo handled automatically)
ai-sandbox claude ~/project --block-cmd "git:push"
```

## How It Works

### Loading

The userspace loader resolves the container's cgroup v2 path to a numeric cgroup ID using `name_to_handle_at`. It then opens and loads the compiled BPF object via the libbpf skeleton and populates three BPF maps:

- **`target_cgroup`** (array, 1 entry) — the cgroup ID to scope enforcement to.
- **`blocked_cmds`** (hash map) — binary-only rules (arg1 is empty). Checked in the LSM hook.
- **`blocked_cmds_arg`** (hash map) — binary+arg1 rules. Checked in the tracepoint.

### Enforcement: Dual-Hook Architecture

Two BPF hooks work together because argv is not available at the same point in the kernel:

**Hook 1 — LSM `bprm_check_security`** (binary-only rules)

This hook fires before `execve` completes. At this point the kernel knows the binary path but argv is not yet readable from user memory. The BPF program extracts the basename, looks it up in the `blocked_cmds` map (where arg1 is empty), and returns `-EPERM` on match. The command is never executed.

**Hook 2 — Tracepoint `sched_process_exec`** (binary+arg rules)

This tracepoint fires after exec, when the new process is set up and argv is readable from `mm->arg_start`. The BPF program reads argv[0] to find argv[1]'s address, then reads argv[1] and looks up the `(binary, arg1)` pair in the `blocked_cmds_arg` map. On match, it sends `SIGKILL` — the process is killed immediately.

Both hooks first check whether the calling process belongs to the target cgroup via `bpf_get_current_cgroup_id()`. Non-matching cgroups are allowed through without any overhead.

### Cleanup

When the loader receives `SIGINT` or `SIGTERM`, it calls `block_commands_bpf__destroy()` to detach both BPF programs, remove the maps, and release all resources. Blocking is cleanly removed when the loader exits.

## Limits

Defined in `config.h`:

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_BIN_LEN` | 64 | Maximum binary name length (truncated at 63 chars) |
| `MAX_ARG_LEN` | 64 | Maximum arg1 length (truncated at 63 chars) |
| `MAX_BLOCKED_CMDS` | 64 | Maximum number of blocked command rules per map |

These are compile-time constants. To change them, edit `config.h` and rebuild.

## Troubleshooting

### Verifying That Blocking Works

Both BPF hooks write to the kernel trace buffer via `bpf_printk`. To see blocking events in real time:

```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe | grep BLOCKED
```

You'll see lines like:

```
<...>-12345  [...] BLOCKED: curl (pid 12345)
<...>-12346  [...] BLOCKED+KILL: git push (pid 12346)
```

- `BLOCKED` — binary-only rule fired (LSM hook, exec denied with `-EPERM`)
- `BLOCKED+KILL` — binary+arg rule fired (tracepoint, process killed with `SIGKILL`)

### Inspecting BPF State

Use `bpftool` to inspect loaded programs, maps, and links. All commands require `sudo`.

**Programs** — verify both hooks are loaded:

```bash
sudo bpftool prog list | grep -A2 block_cmd
```

You should see two entries: `block_cmd_check` (LSM) and `block_cmd_arg_check` (tracepoint).

**Maps** — verify rules and target cgroup:

```bash
# List all BPF maps
sudo bpftool map list

# Dump binary-only rules (arg1 empty)
sudo bpftool map dump name blocked_cmds

# Dump binary+arg rules
sudo bpftool map dump name blocked_cmds_arg

# Dump target cgroup ID
sudo bpftool map dump name target_cgroup
```

**Links** — verify hooks are attached:

```bash
sudo bpftool link list
```

Look for entries referencing `block_cmd_check` (LSM attach) and `block_cmd_arg_check` (tracing attach).

### Manual Cleanup

Normally the loader handles cleanup automatically via `block_commands_bpf__destroy()` when it receives `SIGINT` or `SIGTERM`. These commands are only needed if the loader was killed abnormally (e.g. `SIGKILL`) and BPF programs remain attached.

```bash
# Find orphaned links
sudo bpftool link list
# Look for entries with prog name "block_cmd_check" or "block_cmd_arg_check"

# Delete a link (detaches the hook and frees resources)
sudo bpftool link delete id <LINK_ID>

# Verify cleanup is complete (should return nothing)
sudo bpftool prog list | grep block_cmd
```

Repeat `link delete` for each orphaned link. Once no programs show up in `prog list`, the system is clean.

### Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `failed to load BPF program` | BPF LSM not enabled in kernel | Add `bpf` to `CONFIG_LSM` / kernel cmdline `lsm=...,bpf` |
| `failed to open BPF skeleton` | Missing CAP_BPF / not running as root | Run with `sudo` |
| `cannot open cgroup path` | Wrong cgroup path or container not running | Verify with `podman inspect --format '{{.State.CgroupPath}}'` |
| `name_to_handle_at failed` | Kernel too old or cgroup2 not mounted | Check `mount | grep cgroup2` |
| Command not blocked | Binary name longer than 63 chars, or arg1 mismatch | Check limits in `config.h`; use `--verbose` to verify rules |
| Programs still loaded after stopping loader | Loader killed with `SIGKILL` or crashed | See [Manual Cleanup](#manual-cleanup) above |
