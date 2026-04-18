#!/bin/bash
# =============================================================================
# End-to-end tests for the BPF LSM command blocker.
# Requires root privileges and a built environment (loader + container images).
#
# Usage: sudo bash test/test_bpf_blocker.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOADER="${PROJECT_DIR}/bpf/loader"
CONTAINER_NAME="test-bpf-$$"
TEST_IMAGE="localhost/agent-claude:latest"

# --- Prerequisites -----------------------------------------------------------

check_prerequisites() {
    echo "=== BPF Command Blocker — End-to-End Tests ==="
    echo ""
    echo "Checking prerequisites..."

    local ok=true

    if ! command -v podman &>/dev/null; then
        echo -e "  ${RED}✗${NC} podman not found"
        ok=false
    else
        echo -e "  ${GREEN}✓${NC} podman"
    fi

    if ! command -v bpftool &>/dev/null; then
        echo -e "  ${RED}✗${NC} bpftool not found"
        ok=false
    else
        echo -e "  ${GREEN}✓${NC} bpftool"
    fi

    if ! sudo -n true 2>/dev/null; then
        echo -e "  ${RED}✗${NC} sudo access not available"
        ok=false
    else
        echo -e "  ${GREEN}✓${NC} sudo"
    fi

    if [[ ! -x "$LOADER" ]]; then
        echo -e "  ${YELLOW}!${NC} loader not found, attempting make -C bpf/"
        if make -C "${PROJECT_DIR}/bpf/" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} loader (built)"
        else
            echo -e "  ${RED}✗${NC} loader build failed"
            ok=false
        fi
    else
        echo -e "  ${GREEN}✓${NC} loader"
    fi

    if ! podman image exists "$TEST_IMAGE" 2>/dev/null; then
        for img in localhost/agent-codex:latest localhost/agent-cursor:latest; do
            if podman image exists "$img" 2>/dev/null; then
                TEST_IMAGE="$img"
                break
            fi
        done
        if ! podman image exists "$TEST_IMAGE" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} no agent image found"
            ok=false
        else
            echo -e "  ${GREEN}✓${NC} agent image ($TEST_IMAGE)"
        fi
    else
        echo -e "  ${GREEN}✓${NC} agent image ($TEST_IMAGE)"
    fi

    if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
        echo -e "  ${RED}✗${NC} /sys/kernel/btf/vmlinux not found (no BTF support)"
        ok=false
    else
        echo -e "  ${GREEN}✓${NC} BTF support"
    fi

    if ! cat /sys/kernel/security/lsm 2>/dev/null | grep -q bpf; then
        echo -e "  ${RED}✗${NC} bpf not in LSM list (cat /sys/kernel/security/lsm)"
        ok=false
    else
        echo -e "  ${GREEN}✓${NC} BPF LSM enabled"
    fi

    echo ""

    if [[ "$ok" != true ]]; then
        echo -e "${RED}Prerequisites not met. Aborting.${NC}"
        exit 1
    fi
}

# --- Test helpers ------------------------------------------------------------

run_test() {
    local name="$1"
    echo -ne "  ${CYAN}TEST${NC}: ${name}... "
}

pass() {
    echo -e "${GREEN}PASS${NC}"
    ((PASS++))
}

fail() {
    local reason="${1:-}"
    echo -e "${RED}FAIL${NC}${reason:+ ($reason)}"
    ((FAIL++))
}

resolve_cgroup() {
    local container_id="$1"
    local cg_path
    cg_path=$(podman inspect --format '{{.CgroupPath}}' "$container_id" 2>/dev/null)

    if [[ -z "$cg_path" ]]; then
        echo ""
        return
    fi

    local full_cg
    if [[ "$cg_path" == /sys/fs/cgroup/* ]]; then
        full_cg="$cg_path"
    else
        full_cg="/sys/fs/cgroup${cg_path}"
    fi

    if [[ ! -d "$full_cg" ]]; then
        full_cg="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service${cg_path}"
    fi

    if [[ ! -d "$full_cg" ]]; then
        echo ""
        return
    fi

    echo "$full_cg"
}

# Start a container + loader, sets CONTAINER_ID and LOADER_PID globals.
# Usage: setup_blocked_container "git:push"
setup_blocked_container() {
    local block_rule="$1"
    local tmpdir
    tmpdir=$(mktemp -d)

    git init "$tmpdir" &>/dev/null
    git -C "$tmpdir" commit --allow-empty -m "init" &>/dev/null

    local workdir
    workdir="/workspace/$(basename "$tmpdir")"

    CONTAINER_ID=$(podman run -d --rm \
        --name "$CONTAINER_NAME" \
        --userns=keep-id \
        --cap-drop=ALL \
        --read-only \
        --tmpfs /tmp:rw \
        --mount "type=tmpfs,destination=/home/agent,tmpfs-mode=0755,U=true" \
        -v "${tmpdir}:${workdir}:Z" \
        -w "${workdir}" \
        "$TEST_IMAGE" sleep 300)

    podman wait --condition=running "$CONTAINER_ID" >/dev/null 2>&1 || sleep 1

    local full_cg
    full_cg=$(resolve_cgroup "$CONTAINER_ID")

    if [[ -z "$full_cg" ]]; then
        echo -e "${RED}Could not resolve cgroup for container${NC}" >&2
        teardown_container
        return 1
    fi

    sudo "$LOADER" --cgroup "$full_cg" --block "$block_rule" &>/dev/null &
    LOADER_PID=$!
    sleep 1

    TMPDIR_CLEANUP="$tmpdir"
    return 0
}

teardown_container() {
    if [[ -n "${LOADER_PID:-}" ]]; then
        sudo kill "$LOADER_PID" 2>/dev/null || true
        wait "$LOADER_PID" 2>/dev/null || true
        unset LOADER_PID
    fi
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    if [[ -n "${TMPDIR_CLEANUP:-}" ]]; then
        rm -rf "$TMPDIR_CLEANUP"
        unset TMPDIR_CLEANUP
    fi
}

# --- Tests -------------------------------------------------------------------

test_git_push_blocked() {
    run_test "git push is blocked inside container"

    if ! setup_blocked_container "git:push"; then
        fail "setup failed"
        return
    fi

    local output
    local rc=0
    output=$(podman exec "$CONTAINER_NAME" git push 2>&1) || rc=$?

    if [[ $rc -ne 0 ]] && echo "$output" | grep -qi "operation not permitted\|permission denied\|EPERM"; then
        pass
    else
        fail "exit=$rc, output: $output"
    fi

    teardown_container
}

test_git_commit_not_blocked() {
    run_test "git commit is NOT blocked inside container"

    if ! setup_blocked_container "git:push"; then
        fail "setup failed"
        return
    fi

    local rc=0
    podman exec "$CONTAINER_NAME" git commit --allow-empty -m "test commit" &>/dev/null || rc=$?

    if [[ $rc -eq 0 ]]; then
        pass
    else
        fail "exit=$rc"
    fi

    teardown_container
}

test_git_pull_not_blocked() {
    run_test "git pull is NOT blocked inside container"

    if ! setup_blocked_container "git:push"; then
        fail "setup failed"
        return
    fi

    local output
    local rc=0
    output=$(podman exec "$CONTAINER_NAME" git pull 2>&1) || rc=$?

    if echo "$output" | grep -qi "operation not permitted"; then
        fail "got EPERM"
    else
        pass
    fi

    teardown_container
}

test_host_not_affected() {
    run_test "git push works on the host (cgroup scoping)"

    local tmpdir
    tmpdir=$(mktemp -d)
    git init "$tmpdir" &>/dev/null
    git -C "$tmpdir" commit --allow-empty -m "init" &>/dev/null

    local output
    local rc=0
    output=$(git -C "$tmpdir" push 2>&1) || rc=$?

    if echo "$output" | grep -qi "operation not permitted"; then
        fail "host got EPERM"
    else
        pass
    fi

    rm -rf "$tmpdir"
}

test_cleanup_after_loader_exit() {
    run_test "BPF program is cleaned up after loader exit"

    if ! setup_blocked_container "git:push"; then
        fail "setup failed"
        return
    fi

    sudo kill "$LOADER_PID" 2>/dev/null || true
    wait "$LOADER_PID" 2>/dev/null || true
    unset LOADER_PID

    sleep 0.5

    if sudo bpftool prog list 2>/dev/null | grep -q "block_cmd_check"; then
        fail "BPF program still loaded"
    else
        pass
    fi

    teardown_container
}

# --- Main --------------------------------------------------------------------

check_prerequisites

echo "Running tests..."
echo ""

test_git_push_blocked
test_git_commit_not_blocked
test_git_pull_not_blocked
test_host_not_affected
test_cleanup_after_loader_exit

echo ""
echo "=============================="
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
