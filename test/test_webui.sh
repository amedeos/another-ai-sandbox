#!/bin/bash
# =============================================================================
# End-to-end tests for the web UI: session opt-in isolation, dashboard auth,
# dual attach, image paste and cleanup.
#
# Unlike the BPF test this needs NO root — everything runs rootless.
# Requires built container images and python3.
#
# Usage: bash test/test_webui.sh
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

AI_SANDBOX="${PROJECT_DIR}/ai-sandbox"
WEB_BIN="${PROJECT_DIR}/web/ai-sandbox-web"
TEST_IMAGE="localhost/agent-claude:latest"
TEST_AGENT="claude"
WORK_DIR=""
WEB_PORT=""
WEB_PID=""
TOKEN=""
TOKEN_FILE=""
STAGING=""

# --- Prerequisites -----------------------------------------------------------

check_prerequisites() {
    echo "=== ai-sandbox Web UI — End-to-End Tests ==="
    echo ""
    echo "Checking prerequisites..."

    local ok=true

    if command -v podman >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} podman"
    else
        echo -e "  ${RED}✗${NC} podman — not found"
        ok=false
    fi

    if command -v python3 >/dev/null 2>&1 &&
       python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
        echo -e "  ${GREEN}✓${NC} python3 (3.9+)"
    else
        echo -e "  ${RED}✗${NC} python3 3.9+ — not found"
        ok=false
    fi

    if command -v curl >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} curl"
    else
        echo -e "  ${RED}✗${NC} curl — not found"
        ok=false
    fi

    # Any agent image will do, as long as it carries zellij.
    local img
    for img in agent-claude agent-codex agent-cursor agent-opencode; do
        if podman image exists "localhost/${img}:latest" 2>/dev/null; then
            TEST_IMAGE="localhost/${img}:latest"
            case "$img" in
                agent-claude)   TEST_AGENT="claude" ;;
                agent-codex)    TEST_AGENT="codex" ;;
                agent-cursor)   TEST_AGENT="cursor" ;;
                agent-opencode) TEST_AGENT="opencode" ;;
            esac
            break
        fi
    done

    if podman image exists "$TEST_IMAGE" 2>/dev/null; then
        local zj
        zj="$(podman image inspect --format '{{index .Config.Labels "ai-sandbox.zellij"}}' \
              "$TEST_IMAGE" 2>/dev/null || true)"
        if [[ -n "$zj" ]]; then
            echo -e "  ${GREEN}✓${NC} ${TEST_IMAGE} (zellij ${zj})"
        else
            echo -e "  ${RED}✗${NC} ${TEST_IMAGE} has no zellij — rebuild with 'ai-sandbox --build all'"
            ok=false
        fi
    else
        echo -e "  ${RED}✗${NC} no agent image found — run 'ai-sandbox --build all'"
        ok=false
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

skip() {
    local reason="${1:-}"
    echo -e "${YELLOW}SKIP${NC}${reason:+ ($reason)}"
}

# Start a long-lived session.
#
# This mirrors what `ai-sandbox --web` builds -- same hardening flags, same
# labels, same ai-sandbox-supervise entrypoint -- but runs a shell in place of
# the agent, because every real agent CLI either exits at once or needs
# credentials the test cannot assume. test_web_session_labels covers the real
# script's own output; everything else needs a session that stays up.
start_web_session() {
    local name="$1"

    podman run -d --rm --name "sandbox-${name}" \
        --userns=keep-id:uid=1000,gid=1000 \
        --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 \
        --read-only --network=none \
        -v "${WORK_DIR}:/workspace/work:Z" \
        --tmpfs "/tmp:rw,size=256m" \
        --mount "type=tmpfs,destination=/home/agent,tmpfs-size=256m,tmpfs-mode=0755,U=true" \
        -w /workspace/work \
        --label "ai-sandbox.web=1" \
        --label "ai-sandbox.session=${name}" \
        --label "ai-sandbox.agent=${TEST_AGENT}" \
        --label "ai-sandbox.workdir=/workspace/work" \
        --label "ai-sandbox.cols=100" \
        --label "ai-sandbox.rows=30" \
        --label "ai-sandbox.network=none" \
        -e "AI_SANDBOX_WEB=1" -e "AI_SANDBOX_SESSION=${name}" \
        --entrypoint /usr/local/bin/ai-sandbox-supervise \
        "$TEST_IMAGE" /bin/bash -c 'while :; do sleep 5; done' >/dev/null 2>&1 || return 1

    local i
    for ((i = 0; i < 60; i++)); do
        if podman exec "sandbox-${name}" zellij --session "$name" \
                action list-clients >/dev/null 2>&1; then
            # Let the supervisor's startup-tip sweep finish, so the agent pane
            # is focused before any client attaches.
            sleep 5
            return 0
        fi
        sleep 0.5
    done
    return 1
}

teardown_session() {
    local name="$1"
    podman rm -f "sandbox-${name}" >/dev/null 2>&1 || true
}

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

start_dashboard() {
    WEB_PORT="$(free_port)"
    STAGING="$(mktemp -d)"
    TOKEN_FILE="${STAGING}/token"

    # Serve the repository's own assets, plus a placeholder for the vendored
    # xterm.js that install.sh would normally fetch.
    install -d "${STAGING}/static/vendor"
    install -m 644 "${PROJECT_DIR}"/web/static/*.html "${PROJECT_DIR}"/web/static/*.css \
                   "${PROJECT_DIR}"/web/static/*.js "${STAGING}/static/"
    : > "${STAGING}/static/vendor/xterm.js"
    : > "${STAGING}/static/vendor/xterm.css"

    AI_SANDBOX_WEB_DIR="$STAGING" \
    AI_SANDBOX_WEB_TOKEN_FILE="$TOKEN_FILE" \
    AI_SANDBOX_BIN="$AI_SANDBOX" \
        python3 "$WEB_BIN" --addr 127.0.0.1 --port "$WEB_PORT" \
        > "${STAGING}/web.log" 2>&1 &
    WEB_PID=$!

    local i
    for ((i = 0; i < 40; i++)); do
        if [[ -s "$TOKEN_FILE" ]] &&
           curl -s -o /dev/null "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null; then
            TOKEN="$(cat "$TOKEN_FILE")"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

stop_dashboard() {
    [[ -n "$WEB_PID" ]] && kill "$WEB_PID" 2>/dev/null
    [[ -n "$STAGING" ]] && rm -rf "$STAGING"
    WEB_PID=""
}

# curl against the dashboard with a valid token
web() {
    local method="$1" path="$2"; shift 2
    curl -s -X "$method" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "X-AI-Sandbox: 1" \
        "$@" "http://127.0.0.1:${WEB_PORT}${path}"
}

status_of() {
    local method="$1" path="$2"; shift 2
    curl -s -o /dev/null -w '%{http_code}' -X "$method" \
        "$@" "http://127.0.0.1:${WEB_PORT}${path}"
}

client_count() {
    local name="$1"
    podman exec "sandbox-${name}" zellij --session "$name" action list-clients 2>/dev/null |
        tail -n +2 | grep -c . || true
}

# --- Tests -------------------------------------------------------------------

# A session started without --web must be invisible to the web layer, not
# merely refused by it.
test_optin_isolation() {
    run_test "sessions without --web are invisible"

    podman run -d --rm --name "webtest-plain-$$" \
        --entrypoint /bin/sleep "$TEST_IMAGE" 300 >/dev/null 2>&1 || {
        fail "could not start the control container"
        return
    }

    local all labelled listed
    all="$(podman ps -q | wc -l)"
    labelled="$(podman ps --filter label=ai-sandbox.web=1 -q | wc -l)"
    listed="$(web GET /api/sessions)"

    podman rm -f "webtest-plain-$$" >/dev/null 2>&1 || true

    if [[ "$all" -gt 0 && "$labelled" -eq 0 ]] &&
       ! grep -q "webtest-plain" <<<"$listed"; then
        pass
    else
        fail "running=${all} labelled=${labelled}"
    fi
}

test_auth_required() {
    run_test "the dashboard requires a token"

    local none bad good evil
    none="$(status_of GET /api/sessions)"
    bad="$(status_of GET /api/sessions -H 'Authorization: Bearer wrong')"
    good="$(status_of GET /api/sessions -H "Authorization: Bearer ${TOKEN}")"
    # DNS-rebinding defence: a Host we never bound is refused outright.
    evil="$(status_of GET /api/sessions -H "Authorization: Bearer ${TOKEN}" -H 'Host: evil.example')"

    if [[ "$none" == 401 && "$bad" == 401 && "$good" == 200 && "$evil" == 403 ]]; then
        pass
    else
        fail "none=${none} bad=${bad} good=${good} evil=${evil}"
    fi
}

test_csrf_header_required() {
    run_test "state-changing requests need X-AI-Sandbox"

    local code
    code="$(status_of POST /api/sessions -H "Authorization: Bearer ${TOKEN}")"
    if [[ "$code" == 403 ]]; then
        pass
    else
        fail "expected 403, got ${code}"
    fi
}

# The start API must never turn request data into an arbitrary mount.
test_start_rejects_bad_directory() {
    run_test "the start API refuses directories outside the allowed roots"

    local before after body
    before="$(podman ps -q | wc -l)"
    body="$(web POST /api/sessions -H 'Content-Type: application/json' \
        -d '{"agent":"claude","dirs":["/etc"]}')"
    after="$(podman ps -q | wc -l)"

    if grep -q 'error' <<<"$body" && [[ "$before" == "$after" ]]; then
        pass
    else
        fail "body=${body}"
    fi
}

test_start_rejects_unknown_agent() {
    run_test "the start API refuses an unknown agent"

    local body
    body="$(web POST /api/sessions -H 'Content-Type: application/json' \
        -d "{\"agent\":\"../../bin/sh\",\"dirs\":[\"${WORK_DIR}\"]}")"
    if grep -q 'unknown agent' <<<"$body"; then
        pass
    else
        fail "body=${body}"
    fi
}

# The real script's own output: `ai-sandbox --web` must produce the opt-in
# label set, and the dashboard must pick the session up from it.
test_web_session_labels() {
    run_test "ai-sandbox --web labels the container and the dashboard sees it"

    local name="wtr$$"
    "$AI_SANDBOX" "$TEST_AGENT" "$WORK_DIR" \
        --web --web-name "$name" --web-size 111x33 \
        --network-off --non-interactive -- --version >/dev/null 2>&1 || true

    # The agent exits at once, so read the labels before --rm takes it away.
    local labels listed
    labels="$(podman inspect --format \
        '{{index .Config.Labels "ai-sandbox.web"}}/{{index .Config.Labels "ai-sandbox.session"}}/{{index .Config.Labels "ai-sandbox.cols"}}' \
        "sandbox-${name}" 2>/dev/null || true)"
    listed="$(web GET /api/sessions)"
    teardown_session "$name"

    if [[ "$labels" == "1/${name}/111" ]] && grep -q "$name" <<<"$listed"; then
        pass
    elif [[ -z "$labels" ]]; then
        skip "session exited before it could be inspected"
    else
        fail "labels=${labels}"
    fi
}

test_web_session_listed() {
    run_test "a --web session is listed with its parameters"

    if ! start_web_session "wt1$$"; then
        fail "session did not start"
        teardown_session "wt1$$"
        return
    fi

    local body
    body="$(web GET /api/sessions)"
    if grep -q "wt1$$" <<<"$body" && grep -q '"cols": 100' <<<"$body"; then
        pass
    else
        fail "body=${body}"
    fi
}

# The core property: two clients on one session, and losing one loses neither
# the session nor the other client.
test_dual_attach() {
    run_test "two clients share one session, and detaching keeps it alive"

    local name="wt1$$"
    if ! podman container exists "sandbox-${name}" 2>/dev/null; then
        skip "no session"
        return
    fi

    # Client A: a terminal client, exactly as `ai-sandbox attach` makes one.
    podman exec -i "sandbox-${name}" zellij attach "$name" >/dev/null 2>&1 &
    local pid_a=$!
    sleep 3

    # Client B: the browser, through the dashboard's own PTY.
    local attach_id
    attach_id="$(web POST "/api/sessions/${name}/attach" |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("attach_id",""))')"
    if [[ -z "$attach_id" ]]; then
        fail "browser could not attach"
        kill "$pid_a" 2>/dev/null
        return
    fi

    curl -s -N -H "Authorization: Bearer ${TOKEN}" \
        "http://127.0.0.1:${WEB_PORT}/api/attach/${attach_id}/stream" >/dev/null 2>&1 &
    local pid_stream=$!
    sleep 3

    local both
    both="$(client_count "$name")"

    # zellij collapses a shared session to its smallest client, so a browser
    # must not impose its own size while a terminal is attached.
    local resize
    resize="$(status_of POST "/api/attach/${attach_id}/resize" \
        -H "Authorization: Bearer ${TOKEN}" -H 'X-AI-Sandbox: 1' \
        -H 'Content-Type: application/json' -d '{"cols":200,"rows":60}')"

    kill "$pid_stream" 2>/dev/null
    sleep 4
    local after_browser
    after_browser="$(client_count "$name")"

    kill "$pid_a" 2>/dev/null
    sleep 2
    local alive="no"
    podman container exists "sandbox-${name}" 2>/dev/null && alive="yes"

    if [[ "$both" -ge 2 && "$resize" == 409 && "$after_browser" -lt "$both" && "$alive" == yes ]]; then
        pass
    else
        fail "clients=${both} resize=${resize} after=${after_browser} alive=${alive}"
    fi
}

test_paste_image() {
    run_test "a pasted image lands in the container and its path is typed"

    local name="wt1$$"
    if ! podman container exists "sandbox-${name}" 2>/dev/null; then
        skip "no session"
        return
    fi

    local attach_id
    attach_id="$(web POST "/api/sessions/${name}/attach" |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("attach_id",""))')"
    if [[ -z "$attach_id" ]]; then
        fail "could not attach"
        return
    fi

    local png="${STAGING}/t.png"
    python3 -c "import base64,sys; open(sys.argv[1],'wb').write(base64.b64decode(
'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))" "$png"

    local rejected accepted path
    rejected="$(status_of POST "/api/attach/${attach_id}/paste" \
        -H "Authorization: Bearer ${TOKEN}" -H 'X-AI-Sandbox: 1' \
        --data-binary 'this is not an image')"
    accepted="$(web POST "/api/attach/${attach_id}/paste" --data-binary "@${png}")"
    path="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("path",""))' <<<"$accepted")"

    local present="no"
    if [[ -n "$path" ]] && podman exec "sandbox-${name}" test -f "$path" 2>/dev/null; then
        present="yes"
    fi

    web DELETE "/api/attach/${attach_id}" >/dev/null 2>&1 || true

    if [[ "$rejected" == 400 && "$present" == yes ]]; then
        pass
    else
        fail "rejected=${rejected} path=${path} present=${present}"
    fi
}

test_attach_refuses_non_web_container() {
    run_test "attach and stop refuse a container without the opt-in label"

    podman run -d --rm --name "sandbox-decoy$$" \
        --entrypoint /bin/sleep "$TEST_IMAGE" 120 >/dev/null 2>&1 || {
        fail "could not start the decoy"
        return
    }

    local attach_rc=0 stop_rc=0 api
    "$AI_SANDBOX" attach "decoy$$" >/dev/null 2>&1 || attach_rc=$?
    "$AI_SANDBOX" stop "decoy$$" >/dev/null 2>&1 || stop_rc=$?
    api="$(status_of POST "/api/sessions/decoy$$/attach" \
        -H "Authorization: Bearer ${TOKEN}" -H 'X-AI-Sandbox: 1')"

    podman rm -f "sandbox-decoy$$" >/dev/null 2>&1 || true

    if [[ $attach_rc -ne 0 && $stop_rc -ne 0 && "$api" == 404 ]]; then
        pass
    else
        fail "attach=${attach_rc} stop=${stop_rc} api=${api}"
    fi
}

test_invalid_session_name_rejected() {
    run_test "a traversal session name is rejected"

    local rc=0
    "$AI_SANDBOX" attach "../etc" >/dev/null 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        pass
    else
        fail "accepted ../etc"
    fi
}

# Keeps the README's promise that the web UI adds no host<->container plumbing.
test_container_cannot_reach_dashboard() {
    run_test "a sandbox cannot reach the dashboard"

    local name="wt2$$"
    if ! start_web_session "$name"; then
        skip "session did not start"
        teardown_session "$name"
        return
    fi

    local reached=no host_ip
    host_ip="$(podman exec "sandbox-${name}" sh -c \
        "ip route 2>/dev/null | awk '/default/ {print \$3; exit}'" 2>/dev/null || true)"
    local target
    for target in ${host_ip:-} host.containers.internal 127.0.0.1; do
        if podman exec "sandbox-${name}" curl -s --max-time 3 -o /dev/null \
                "http://${target}:${WEB_PORT}/api/sessions" 2>/dev/null; then
            reached=yes
        fi
    done

    teardown_session "$name"

    if [[ "$reached" == no ]]; then
        pass
    else
        fail "the dashboard was reachable from inside a sandbox"
    fi
}

# The whole supervisor -> --rm chain: agent exits, session goes, container goes.
test_session_cleanup() {
    run_test "the container is removed once the agent exits"

    local name="wt1$$"
    if ! podman container exists "sandbox-${name}" 2>/dev/null; then
        skip "no session"
        return
    fi

    podman exec "sandbox-${name}" zellij kill-session "$name" >/dev/null 2>&1 || true

    local i gone=no
    for ((i = 0; i < 30; i++)); do
        if ! podman container exists "sandbox-${name}" 2>/dev/null; then
            gone=yes
            break
        fi
        sleep 1
    done

    teardown_session "$name"

    if [[ "$gone" == yes ]]; then
        pass
    else
        fail "container still present after 30s"
    fi
}

test_no_prompt_without_tty() {
    run_test "--web fails instead of hanging without a terminal"

    local rc=0
    env -u ANTHROPIC_API_KEY timeout 30 "$AI_SANDBOX" claude "$WORK_DIR" \
        --web --web-name "wt3$$" </dev/null >/dev/null 2>&1 || rc=$?

    teardown_session "wt3$$"

    # 124 is timeout(1) — it hung, which is the failure this guards against.
    if [[ $rc -ne 0 && $rc -ne 124 ]]; then
        pass
    else
        fail "exit=${rc}"
    fi
}

# --- Main --------------------------------------------------------------------

cleanup() {
    stop_dashboard
    teardown_session "wt1$$"
    teardown_session "wt2$$"
    teardown_session "wt3$$"
    podman rm -f "webtest-plain-$$" "sandbox-decoy$$" "sandbox-wtr$$" >/dev/null 2>&1 || true
    [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

check_prerequisites

WORK_DIR="$(mktemp -d)"
if ! start_dashboard; then
    echo -e "${RED}Could not start the dashboard. Aborting.${NC}"
    exit 1
fi

echo "Running tests..."
echo ""

test_auth_required
test_csrf_header_required
test_optin_isolation
test_start_rejects_bad_directory
test_start_rejects_unknown_agent
test_web_session_labels
test_web_session_listed
test_dual_attach
test_paste_image
test_attach_refuses_non_web_container
test_invalid_session_name_rejected
test_container_cannot_reach_dashboard
test_session_cleanup
test_no_prompt_without_tty

echo ""
echo "=============================="
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
