// SPDX-License-Identifier: GPL-3.0-or-later
// another-ai-sandbox
//
// BPF LSM program that hooks into bprm_check_security to block execution of
// configured commands, scoped to a specific cgroup v2. Populated via userspace
// loader.

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "config.h"

struct blocked_cmd_key {
    char binary[MAX_BIN_LEN];
    char arg1[MAX_ARG_LEN];
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, struct blocked_cmd_key);
    __type(value, __u8);
    __uint(max_entries, MAX_BLOCKED_CMDS);
} blocked_cmds SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, 1);
} target_cgroup SEC(".maps");

SEC("lsm/bprm_check_security")
int BPF_PROG(block_cmd_check, struct linux_binprm *bprm, int ret)
{
    if (ret != 0)
        return ret;

    __u32 zero = 0;
    __u64 *target_cg = bpf_map_lookup_elem(&target_cgroup, &zero);
    if (!target_cg)
        return 0;

    __u64 current_cg = bpf_get_current_cgroup_id();
    if (current_cg != *target_cg)
        return 0;

    char filename[MAX_BIN_LEN];
    int fname_len;

    fname_len = bpf_probe_read_kernel_str(filename, sizeof(filename),
                                          BPF_CORE_READ(bprm, filename));
    if (fname_len <= 0)
        return 0;

    /* Extract basename: scan backwards for '/' */
    int basename_off = 0;
    for (int i = fname_len - 1; i >= 0; i--) {
        if (i >= MAX_BIN_LEN)
            continue;
        if (filename[i] == '/') {
            basename_off = i + 1;
            break;
        }
    }

    struct blocked_cmd_key key = {};

    /* Copy basename into key.binary with bounds checking */
    for (int i = 0; i < MAX_BIN_LEN - 1; i++) {
        int src = basename_off + i;
        if (src < 0 || src >= MAX_BIN_LEN)
            break;
        if (filename[src] == '\0')
            break;
        key.binary[i] = filename[src];
    }

    /* Read argv[1] from bprm->mm->arg_start */
    unsigned long arg_start = BPF_CORE_READ(bprm, mm, arg_start);
    unsigned long arg_end = BPF_CORE_READ(bprm, mm, arg_end);

    if (arg_start != 0 && arg_end > arg_start) {
        /* Read argv[0] to determine its length */
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

    __u8 *blocked = bpf_map_lookup_elem(&blocked_cmds, &key);
    if (blocked) {
        __u32 pid = bpf_get_current_pid_tgid() >> 32;
        bpf_printk("BLOCKED: %s %s (pid %d)", key.binary, key.arg1, pid);
        return -1;
    }

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
