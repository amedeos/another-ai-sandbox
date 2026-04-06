// SPDX-License-Identifier: GPL-3.0-or-later
// another-ai-sandbox
//
// Userspace loader (libbpf): loads the BPF program, populates blocked_cmds and
// target_cgroup maps, attaches to LSM hook, handles cleanup on SIGINT/SIGTERM.
