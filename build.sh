#!/bin/bash
# =============================================================================
# build.sh - Builds all container images for AI agents
#
# Usage:
#   ./build.sh              # builds everything
#   ./build.sh base         # only the base image
#   ./build.sh claude       # only claude-code (requires base)
#   ./build.sh codex        # only codex (requires base)
#   ./build.sh cursor       # only cursor-agent (requires base)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="podman"  # change to "docker" if needed
BASE_IMAGE="registry.fedoraproject.org/fedora:43"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[BUILD]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

build_image() {
    local name="$1"
    local dir="$2"
    local tag="$3"

    log "Building ${name} -> ${tag}"
    "${BUILDER}" build \
        --format docker \
        --tag "${tag}" \
        --file "${dir}/Containerfile" \
        "${dir}"
    log "${name} built successfully"
}

pull_base_image() {
    log "Pulling latest ${BASE_IMAGE}..."
    "${BUILDER}" pull "${BASE_IMAGE}"
}

build_base() {
    pull_base_image
    build_image "base" "${SCRIPT_DIR}/base" "localhost/agent-base:latest"
}

build_claude() {
    build_image "claude-code" "${SCRIPT_DIR}/claude-code" "localhost/agent-claude:latest"
}

build_codex() {
    build_image "codex" "${SCRIPT_DIR}/codex" "localhost/agent-codex:latest"
}

build_cursor() {
    build_image "cursor-agent" "${SCRIPT_DIR}/cursor-agent" "localhost/agent-cursor:latest"
}

TARGET="${1:-all}"

case "${TARGET}" in
    base)
        build_base
        ;;
    claude)
        build_base
        build_claude
        ;;
    codex)
        build_base
        build_codex
        ;;
    cursor)
        build_base
        build_cursor
        ;;
    all)
        build_base
        log "--- Base ready, building agents ---"
        build_claude
        build_codex
        build_cursor
        log "=== All images built ==="
        "${BUILDER}" images | grep -E 'agent-(base|claude|codex|cursor)'
        ;;
    *)
        err "Unknown target: ${TARGET}"
        echo "Usage: $0 [base|claude|codex|cursor|all]"
        exit 1
        ;;
esac

# Remove dangling images left over from previous builds
DANGLING=$("${BUILDER}" images --filter dangling=true -q 2>/dev/null)
if [[ -n "$DANGLING" ]]; then
    log "Pruning dangling images..."
    echo "$DANGLING" | xargs "${BUILDER}" rmi -f 2>/dev/null || true
    log "Done"
fi
