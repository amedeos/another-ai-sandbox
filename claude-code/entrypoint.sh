#!/bin/bash
# Prepare home directories on tmpfs before starting Claude Code
ln -sfn /opt/claude-local ~/.local
mkdir -p ~/.cache ~/.config
export PATH="${HOME}/.local/bin:${PATH}"
exec claude "$@"
