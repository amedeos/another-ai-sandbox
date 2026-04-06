# BPF LSM Command Blocker

## Overview

BPF LSM-based command blocker that hooks into `bprm_check_security` to prevent execution of specified commands inside containers. It uses cgroup v2 scoping so blocking only applies to the target container, not the host or other containers. Blocked commands are configured at runtime via the userspace loader — no recompilation needed to change the set of blocked commands.

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
Fedora:  dnf install clang llvm libbpf-devel bpftool elfutils-libelf-devel zlib-devel
Gentoo:  emerge -av sys-devel/clang sys-devel/llvm dev-libs/libbpf sys-apps/bpftool dev-libs/elfutils sys-libs/zlib
```

## Build

```bash
cd bpf/
make
```

This compiles the BPF program and the userspace loader, then installs the loader to `~/.local/bin/ai-sandbox-loader`. Override with `make LOADER_DIR=/other/path`.

## Usage

```bash
# Standalone usage
sudo ./loader --cgroup /sys/fs/cgroup/.../libpod-XXX.scope \
              --block "git:push" \
              --block "git:push --force" \
              --verbose

# Via ai-sandbox wrapper
ai-sandbox claude ~/project --block-cmd "git:push"
```

## How It Works

The userspace loader resolves the container's cgroup v2 path to a numeric cgroup ID using `name_to_handle_at`. It then opens and loads the compiled BPF object via the libbpf skeleton and populates two BPF maps: `target_cgroup`, which holds the single cgroup ID to scope enforcement to, and `blocked_cmds`, a hash map keyed by `(binary, arg1)` pairs representing the commands to block.

Once the maps are populated, the loader attaches the BPF program to the LSM hook `bprm_check_security`, which the kernel invokes on every `execve` call. For each execution, the BPF program first checks whether the calling process belongs to the target cgroup. If it does, the program extracts the binary's basename from the full path and reads the first argument from userspace memory, then looks the pair up in the `blocked_cmds` map. If a match is found, it returns `-EPERM`, which causes the kernel to deny the execution. All other processes and non-matching commands are allowed through without interference.

When the loader receives `SIGINT` or `SIGTERM`, it calls `block_commands_bpf__destroy()` to detach the BPF program, remove the maps, and release all resources. This ensures that blocking is cleanly removed when the loader exits.
