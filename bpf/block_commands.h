// SPDX-License-Identifier: GPL-3.0-or-later
// another-ai-sandbox
//
// Shared structures between BPF program and userspace loader: blocked_cmd_key,
// map definitions, constants.

#ifndef BLOCK_COMMANDS_H
#define BLOCK_COMMANDS_H

#include "config.h"

struct blocked_cmd_key {
    char binary[MAX_BIN_LEN];
    char arg1[MAX_ARG_LEN];
};

#endif
