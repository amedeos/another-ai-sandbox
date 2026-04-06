// SPDX-License-Identifier: GPL-3.0-or-later
// another-ai-sandbox
//
// BPF LSM program that hooks into bprm_check_security to block execution of
// configured commands, scoped to a specific cgroup v2. Populated via userspace
// loader.
