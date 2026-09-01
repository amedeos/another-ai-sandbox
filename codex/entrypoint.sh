#!/bin/bash
# Prepare home directories on tmpfs before starting Codex CLI
mkdir -p ~/.cache ~/.config
exec ai-sandbox-supervise codex "$@"
