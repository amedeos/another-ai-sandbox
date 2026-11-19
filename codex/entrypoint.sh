#!/bin/bash
# Prepare home directories on tmpfs before starting Codex CLI

# Change binary symlink
RELEASE_VER=$(ls -1 /home/agent/.codex/packages/app-server-daemon/releases/)
ln -sf /home/agent/.codex/packages/app-server-daemon/releases/${RELEASE_VER} /home/agent/.codex/packages/app-server-daemon/current

mkdir -p ~/.cache ~/.config
exec ai-sandbox-supervise codex "$@" --no-daemon --sandbox danger-full-access
