#!/bin/bash
# Prepare home directories on tmpfs, then generate the opencode provider config
# from the OLLAMA_* variables before starting opencode.
set -euo pipefail

mkdir -p ~/.cache ~/.config/opencode ~/.local/share

BASE_URL="${OLLAMA_BASE_URL:-https://ollama.com/v1}"
MODEL="${OLLAMA_MODEL:-glm-5.2:cloud}"

# Local Ollama endpoints ignore the key, but the OpenAI-compatible client still
# expects a non-empty value, so send a placeholder instead of omitting it.
if [[ "${OLLAMA_NO_API_KEY:-}" == "1" ]]; then
    API_KEY="local"
else
    API_KEY="${OLLAMA_API_KEY:-}"
fi

# Generated with jq so model names and URLs are escaped correctly.
jq -n \
    --arg baseURL "$BASE_URL" \
    --arg apiKey "$API_KEY" \
    --arg model "$MODEL" \
    '{
        "$schema": "https://opencode.ai/config.json",
        provider: {
            ollama: {
                npm: "@ai-sdk/openai-compatible",
                name: "Ollama",
                options: { baseURL: $baseURL, apiKey: $apiKey },
                models: { ($model): { name: $model } }
            }
        },
        model: ("ollama/" + $model)
    }' > ~/.config/opencode/opencode.json

exec opencode "$@"
