// SPDX-License-Identifier: GPL-3.0-or-later
// another-ai-sandbox
//
// BPF programs for command blocking, scoped to a specific cgroup v2.
//
// Two hooks work together:
//   1. LSM bprm_check_security — blocks binary-only rules (arg1 == "")
//      by returning -EPERM before exec completes.
//   2. tp_btf/sched_process_exec — enforces binary+arg1 rules after exec,
//      when argv is readable from user memory.  Sends SIGKILL on match.

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>
#include "config.h"

struct blocked_cmd_key {
    char binary[MAX_BIN_LEN];
    char arg1[MAX_ARG_LEN];
};

/* Rules with arg1 == "" — checked in LSM hook (prevents exec) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, struct blocked_cmd_key);
    __type(value, __u8);
    __uint(max_entries, MAX_BLOCKED_CMDS);
} blocked_cmds SEC(".maps");

/* Rules with arg1 != "" — checked in tracepoint after exec (SIGKILL) */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, struct blocked_cmd_key);
    __type(value, __u8);
    __uint(max_entries, MAX_BLOCKED_CMDS);
} blocked_cmds_arg SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, 1);
} target_cgroup SEC(".maps");

/*
 * Extract basename from a kernel filename pointer into dst.
 * Returns the length from bpf_probe_read_kernel_str, or <= 0 on error.
 */
static __always_inline int read_basename(char *dst, int dst_len,
                                         const char *fname_ptr)
{
    char filename[MAX_BIN_LEN];
    int fname_len;

    fname_len = bpf_probe_read_kernel_str(filename, sizeof(filename),
                                          fname_ptr);
    if (fname_len <= 0)
        return fname_len;

    int basename_off = 0;
    for (int i = fname_len - 1; i >= 0; i--) {
        if (i >= MAX_BIN_LEN)
            continue;
        if (filename[i] == '/') {
            basename_off = i + 1;
            break;
        }
    }

    basename_off &= (MAX_BIN_LEN - 1);
    return bpf_probe_read_kernel_str(dst, dst_len,
                                     fname_ptr + basename_off);
}

static __always_inline int check_target_cgroup(void)
{
    __u32 zero = 0;
    __u64 *target_cg = bpf_map_lookup_elem(&target_cgroup, &zero);
    if (!target_cg)
        return 0;
    return bpf_get_current_cgroup_id() == *target_cg;
}

/* --- Hook 1: LSM — block binary-only rules before exec completes --- */

SEC("lsm/bprm_check_security")
int BPF_PROG(block_cmd_check, struct linux_binprm *bprm, int ret)
{
    if (ret != 0)
        return ret;

    if (!check_target_cgroup())
        return 0;

    const char *fname_ptr = BPF_CORE_READ(bprm, filename);
    struct blocked_cmd_key key = {};

    if (read_basename(key.binary, MAX_BIN_LEN, fname_ptr) <= 0)
        return 0;

    __u8 *blocked = bpf_map_lookup_elem(&blocked_cmds, &key);
    if (blocked) {
        __u32 pid = bpf_get_current_pid_tgid() >> 32;
        bpf_printk("BLOCKED: %s (pid %d)", key.binary, pid);
        return -1;
    }

    return 0;
}

/* --- Hook 2: tracepoint — enforce binary+arg rules post-exec --- */

SEC("tp_btf/sched_process_exec")
int BPF_PROG(block_cmd_arg_check, struct task_struct *p, pid_t old_pid,
             struct linux_binprm *bprm)
{
    if (!check_target_cgroup())
        return 0;

    const char *fname_ptr = BPF_CORE_READ(bprm, filename);
    struct blocked_cmd_key key = {};

    if (read_basename(key.binary, MAX_BIN_LEN, fname_ptr) <= 0)
        return 0;

    /* After exec, argv is in user memory at mm->arg_start */
    unsigned long arg_start = BPF_CORE_READ(p, mm, arg_start);
    unsigned long arg_end = BPF_CORE_READ(p, mm, arg_end);

    if (arg_start != 0 && arg_end > arg_start) {
        char argv0[MAX_ARG_LEN];
        int len0 = bpf_probe_read_user_str(argv0, sizeof(argv0),
                                           (void *)arg_start);
        if (len0 > 0) {
            unsigned long arg1_addr = arg_start + (__u64)len0;
            if (arg1_addr < arg_end)
                bpf_probe_read_user_str(key.arg1, sizeof(key.arg1),
                                        (void *)arg1_addr);
        }
    }

    __u8 *blocked = bpf_map_lookup_elem(&blocked_cmds_arg, &key);
    if (blocked) {
        __u32 pid = bpf_get_current_pid_tgid() >> 32;
        bpf_printk("BLOCKED+KILL: %s %s (pid %d)", key.binary, key.arg1, pid);
        bpf_send_signal(SIGKILL);
    }

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
