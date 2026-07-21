#!/bin/bash
# Prepare home directories on tmpfs, then generate the opencode provider config
# from the AI_SANDBOX_OPENCODE_* variables before starting opencode.
set -euo pipefail

# Created here, as the agent user, so they are writable; then the persistent
# state bind-mounted on /state is linked in. Doing it the other way round —
# bind-mounting straight into /home/agent — leaves the parent directories owned
# by container root and opencode fails with EACCES.
mkdir -p ~/.cache ~/.config/opencode ~/.local/share ~/.local/state
ln -sfn /state/share ~/.local/share/opencode
ln -sfn /state/state ~/.local/state/opencode
ln -sfn /state/cache ~/.cache/opencode

BASE_URL="${AI_SANDBOX_OPENCODE_BASE_URL:-https://ollama.com/v1}"
MODEL="${AI_SANDBOX_OPENCODE_MODEL:-glm-5.2:cloud}"

# Some endpoints (a local Ollama, llama.cpp, …) ignore the key, but the
# OpenAI-compatible client still expects a non-empty value, so send a
# placeholder instead of omitting it.
if [[ "${AI_SANDBOX_OPENCODE_NO_API_KEY:-}" == "1" ]]; then
    API_KEY="local"
else
    API_KEY="${AI_SANDBOX_OPENCODE_API_KEY:-}"
fi

# Generated with jq so model names and URLs are escaped correctly.
# @ai-sdk/openai-compatible covers /v1/chat/completions endpoints; a provider
# exposing only /v1/responses would need @ai-sdk/openai instead.
jq -n \
    --arg baseURL "$BASE_URL" \
    --arg apiKey "$API_KEY" \
    --arg model "$MODEL" \
    '{
        "$schema": "https://opencode.ai/config.json",
        provider: {
            custom: {
                npm: "@ai-sdk/openai-compatible",
                name: "Custom (OpenAI-compatible)",
                options: { baseURL: $baseURL, apiKey: $apiKey },
                models: { ($model): { name: $model } }
            }
        },
        model: ("custom/" + $model)
    }' > ~/.config/opencode/opencode.json

exec opencode "$@"
