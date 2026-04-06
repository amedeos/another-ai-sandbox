// SPDX-License-Identifier: GPL-3.0-or-later
// another-ai-sandbox
//
// Userspace loader (libbpf): loads the BPF program, populates blocked_cmds and
// target_cgroup maps, attaches to LSM hook, handles cleanup on SIGINT/SIGTERM.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <getopt.h>
#include <fcntl.h>
#include <sys/stat.h>

#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#include "block_commands.skel.h"
#include "block_commands.h"
#include "config.h"

struct blocked_entry {
    char binary[MAX_BIN_LEN];
    char arg1[MAX_ARG_LEN];
};

static struct blocked_entry entries[MAX_BLOCKED_CMDS];
static int num_entries = 0;

static volatile sig_atomic_t running = 1;

static void sig_handler(int sig)
{
    (void)sig;
    running = 0;
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "Options:\n"
        "  -c, --cgroup <path>       cgroup v2 path of target container (required)\n"
        "  -b, --block <bin:arg1>    command to block (repeatable, at least one required)\n"
        "  -V, --verbose             enable verbose output\n"
        "  -h, --help                show this help message\n"
        "\n"
        "Example:\n"
        "  sudo ./%s --cgroup /sys/fs/cgroup/.../libpod-XXX.scope --block \"git:push\"\n",
        prog, prog);
}

static int parse_block_arg(const char *arg)
{
    if (num_entries >= MAX_BLOCKED_CMDS) {
        fprintf(stderr, "Error: too many --block entries (max %d)\n",
                MAX_BLOCKED_CMDS);
        return -1;
    }

    const char *colon = strchr(arg, ':');
    if (!colon || colon == arg) {
        fprintf(stderr, "Error: invalid --block format '%s' (expected binary:arg1)\n",
                arg);
        return -1;
    }

    size_t bin_len = (size_t)(colon - arg);
    if (bin_len >= MAX_BIN_LEN)
        bin_len = MAX_BIN_LEN - 1;

    memset(&entries[num_entries], 0, sizeof(entries[num_entries]));
    memcpy(entries[num_entries].binary, arg, bin_len);
    entries[num_entries].binary[bin_len] = '\0';

    const char *a1 = colon + 1;
    size_t arg_len = strlen(a1);
    if (arg_len >= MAX_ARG_LEN)
        arg_len = MAX_ARG_LEN - 1;

    memcpy(entries[num_entries].arg1, a1, arg_len);
    entries[num_entries].arg1[arg_len] = '\0';

    num_entries++;
    return 0;
}

static __u64 get_cgroup_id(const char *path)
{
    int fd = open(path, O_RDONLY | O_DIRECTORY);
    if (fd < 0) {
        fprintf(stderr, "Error: cannot open cgroup path '%s': %s\n",
                path, strerror(errno));
        return 0;
    }

    struct {
        struct file_handle fh;
        unsigned char bytes[8];
    } handle = { .fh = { .handle_bytes = 8 } };

    int mount_id = 0;

    if (name_to_handle_at(fd, "", &handle.fh, &mount_id, AT_EMPTY_PATH) < 0) {
        fprintf(stderr, "Error: name_to_handle_at failed for '%s': %s\n",
                path, strerror(errno));
        close(fd);
        return 0;
    }

    close(fd);

    __u64 cg_id = 0;
    memcpy(&cg_id, handle.fh.f_handle, sizeof(cg_id));
    return cg_id;
}

int main(int argc, char **argv)
{
    const char *cgroup_path = NULL;
    int verbose = 0;

    static const struct option long_opts[] = {
        { "cgroup",  required_argument, NULL, 'c' },
        { "block",   required_argument, NULL, 'b' },
        { "verbose", no_argument,       NULL, 'V' },
        { "help",    no_argument,       NULL, 'h' },
        { NULL,      0,                 NULL,  0  },
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "c:b:Vh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'c':
            cgroup_path = optarg;
            break;
        case 'b':
            if (parse_block_arg(optarg) < 0)
                return 1;
            break;
        case 'V':
            verbose = 1;
            break;
        case 'h':
            print_usage(argv[0]);
            return 0;
        default:
            print_usage(argv[0]);
            return 1;
        }
    }

    if (!cgroup_path) {
        fprintf(stderr, "Error: --cgroup is required\n");
        print_usage(argv[0]);
        return 1;
    }

    if (num_entries == 0) {
        fprintf(stderr, "Error: at least one --block entry is required\n");
        print_usage(argv[0]);
        return 1;
    }

    __u64 cg_id = get_cgroup_id(cgroup_path);
    if (cg_id == 0) {
        fprintf(stderr, "Error: failed to resolve cgroup ID for '%s'\n",
                cgroup_path);
        return 1;
    }

    if (verbose) {
        printf("Cgroup path : %s\n", cgroup_path);
        printf("Cgroup ID   : %llu\n", (unsigned long long)cg_id);
        printf("Blocked commands (%d):\n", num_entries);
        for (int i = 0; i < num_entries; i++)
            printf("  [%d] %s %s\n", i, entries[i].binary, entries[i].arg1);
    }

    struct block_commands_bpf *skel = block_commands_bpf__open();
    if (!skel) {
        fprintf(stderr, "Error: failed to open BPF skeleton: %s\n",
                strerror(errno));
        return 1;
    }

    int err = block_commands_bpf__load(skel);
    if (err) {
        fprintf(stderr, "Error: failed to load BPF program: %s\n",
                strerror(-err));
        block_commands_bpf__destroy(skel);
        return 1;
    }

    int cg_map_fd = bpf_map__fd(skel->maps.target_cgroup);
    __u32 zero = 0;
    err = bpf_map_update_elem(cg_map_fd, &zero, &cg_id, BPF_ANY);
    if (err) {
        fprintf(stderr, "Error: failed to update target_cgroup map: %s\n",
                strerror(errno));
        block_commands_bpf__destroy(skel);
        return 1;
    }

    int cmds_map_fd = bpf_map__fd(skel->maps.blocked_cmds);
    __u8 val = 1;

    for (int i = 0; i < num_entries; i++) {
        struct blocked_cmd_key key = {};
        memcpy(key.binary, entries[i].binary, MAX_BIN_LEN);
        memcpy(key.arg1, entries[i].arg1, MAX_ARG_LEN);

        err = bpf_map_update_elem(cmds_map_fd, &key, &val, BPF_ANY);
        if (err) {
            fprintf(stderr, "Error: failed to add blocked command '%s:%s': %s\n",
                    entries[i].binary, entries[i].arg1, strerror(errno));
            block_commands_bpf__destroy(skel);
            return 1;
        }
    }

    err = block_commands_bpf__attach(skel);
    if (err) {
        fprintf(stderr, "Error: failed to attach BPF program: %s\n",
                strerror(-err));
        block_commands_bpf__destroy(skel);
        return 1;
    }

    printf("BPF LSM loaded — blocking %d commands in cgroup ID %llu. Ctrl+C to exit.\n",
           num_entries, (unsigned long long)cg_id);

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    while (running)
        pause();

    printf("\nDetaching BPF program...\n");
    block_commands_bpf__destroy(skel);
    printf("Cleanup complete.\n");

    return 0;
}
