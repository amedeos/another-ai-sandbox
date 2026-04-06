# SPDX-License-Identifier: GPL-3.0-or-later
# another-ai-sandbox
#
# Build system for BPF program and userspace loader.
# Targets: vmlinux.h, block_commands.bpf.o, block_commands.skel.h, loader,
#          clean.
#
# Build dependencies:
#   Fedora: dnf install clang llvm libbpf-devel bpftool elfutils-libelf-devel zlib-devel
#   Gentoo: emerge -av sys-devel/clang sys-devel/llvm dev-libs/libbpf sys-apps/bpftool dev-libs/elfutils sys-libs/zlib

CLANG      ?= clang
LLC        ?= llc
BPFTOOL    ?= bpftool
CC         ?= gcc
ARCH       := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')
VMLINUX    := /sys/kernel/btf/vmlinux
LOADER_DIR ?= $(HOME)/.local/bin

.PHONY: all clean

all: loader

vmlinux.h:
	$(BPFTOOL) btf dump file $(VMLINUX) format c > vmlinux.h

block_commands.bpf.o: block_commands.bpf.c vmlinux.h config.h
	$(CLANG) -g -O2 -target bpf -D__TARGET_ARCH_$(ARCH) \
		-I. \
		-c block_commands.bpf.c \
		-o block_commands.bpf.o

block_commands.skel.h: block_commands.bpf.o
	$(BPFTOOL) gen skeleton block_commands.bpf.o > block_commands.skel.h

loader: loader.c block_commands.skel.h block_commands.h config.h
	$(CC) -Wall -Wextra -O2 \
		-I. \
		-o loader loader.c \
		-lbpf -lelf -lz
	install -d $(LOADER_DIR)
	install -m 755 loader $(LOADER_DIR)/ai-sandbox-loader

clean:
	rm -f vmlinux.h block_commands.bpf.o block_commands.skel.h loader
	rm -f $(LOADER_DIR)/ai-sandbox-loader
