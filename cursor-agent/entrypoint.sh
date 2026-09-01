#!/bin/bash
# Prepare home directories on tmpfs before starting Cursor Agent
mkdir -p ~/.cache ~/.config
exec ai-sandbox-supervise cursor-agent "$@"
