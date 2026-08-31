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
#
# Deliberately not `set -e`, unlike the other scripts in this repo: a test
# harness runs commands that are *expected* to fail (probing for 401s, killing
# clients that may already be gone), and under -e any missed guard aborts the
# whole run silently after the last thing it printed -- which reads as a hang
# rather than a failure. Each test checks its own conditions explicitly.
set -uo pipefail

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

# Note the assignment form rather than ((PASS++)). Post-increment evaluates to
# the *old* value, so the very first ((PASS++)) -- when PASS is still 0 --
# returns exit status 1. As the last command of a test function that becomes
# the function's status, and the whole run dies after the first passing test.
pass() {
    echo -e "${GREEN}PASS${NC}"
    PASS=$((PASS + 1))
}

fail() {
    local reason="${1:-}"
    echo -e "${RED}FAIL${NC}${reason:+ ($reason)}"
    FAIL=$((FAIL + 1))
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
# $2 is the podman network mode.  It matters: the reachability test below has
# to run with the *default* network, since a container with --network=none
# cannot reach anything and would pass that test no matter what.
start_web_session() {
    local name="$1" network="${2:-none}"

    podman run -d --rm --name "sandbox-${name}" \
        --userns=keep-id:uid=1000,gid=1000 \
        --cap-drop=ALL --security-opt=no-new-privileges --pids-limit=512 \
        --read-only "--network=${network}" \
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
        --label "ai-sandbox.network=${network}" \
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

    # Confine the dashboard to the test's own directory: the default is $HOME,
    # and a test that asked the dashboard to mount something needs a root it
    # controls rather than the developer's home.
    AI_SANDBOX_WEB_DIR="$STAGING" \
    AI_SANDBOX_WEB_TOKEN_FILE="$TOKEN_FILE" \
    AI_SANDBOX_WEB_ROOTS="$WORK_DIR" \
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
    true
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

# Wait up to 20s for the client count to reach `atleast N` or drop `below N`,
# then echo whatever it ended up being.
#
# Polling rather than sleeping: attaching and detaching are not instantaneous
# on either side -- the dashboard notices a closed browser within a second but
# then has to signal `podman exec` and let zellij drop the client -- and a fixed
# sleep here measures the machine's load as much as the code's behaviour.
wait_for_clients() {
    local name="$1" mode="$2" want="$3" i n=0 ok=false
    for ((i = 0; i < 40; i++)); do
        n="$(client_count "$name")"
        case "$mode" in
            atleast) [[ "$n" -ge "$want" ]] && ok=true ;;
            below)   [[ "$n" -lt "$want" ]] && ok=true ;;
        esac
        if [[ "$ok" == true ]]; then
            echo "$n"
            return 0
        fi
        sleep 0.5
    done
    echo "$n"
    return 1
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
    listed="$(web GET /api/sessions || true)"

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

# Being under $HOME is not enough to be safe to mount read-write: ~/.ssh and
# ~/.config/ai-sandbox are, and the second holds the dashboard's own token.
test_start_refuses_hidden_directory() {
    run_test "the start API refuses a hidden directory, and never offers one"

    local before after body listed
    before="$(podman ps -q | wc -l)"
    body="$(web POST /api/sessions -H 'Content-Type: application/json' \
        -d "{\"agent\":\"claude\",\"dirs\":[\"${WORK_DIR}/.secrets\"]}")"
    after="$(podman ps -q | wc -l)"
    listed="$(web GET "/api/dirs?path=${WORK_DIR}/")"

    if grep -q 'hidden directories' <<<"$body" && [[ "$before" == "$after" ]] &&
       ! grep -q '.secrets' <<<"$listed"; then
        pass
    else
        fail "body=${body} listed=${listed}"
    fi
}

# Completion is a filesystem listing driven from the browser, so it has to stay
# inside the same roots a session may be mounted from -- and stay one level
# deep, or a request would cost a walk of everything below it.
test_dirs_completion() {
    run_test "directory completion lists one level, inside the roots, any case"

    local root sub deep outside
    root="$(web GET "/api/dirs?path=${WORK_DIR}/")"
    sub="$(web GET "/api/dirs?path=${WORK_DIR}/Ca")"
    deep="$(web GET "/api/dirs?path=${WORK_DIR}/proj/")"
    outside="$(web GET "/api/dirs?path=/etc")"

    # CaseTest matched from the wrong case, but offered under its real name;
    # nested/ is one level below proj/ and must not appear in the root listing.
    if grep -q '"'"${WORK_DIR}/proj"'"' <<<"$root" &&
       grep -q "CaseTest" <<<"$sub" &&
       ! grep -q "nested" <<<"$root" &&
       grep -q "nested" <<<"$deep" &&
       grep -q "allowed roots" <<<"$outside"; then
        pass
    else
        fail "root=${root} sub=${sub} deep=${deep} outside=${outside}"
    fi
}

# The real script's own output: `ai-sandbox --web` must produce the opt-in
# label set. That the dashboard then picks such a session up is
# test_web_session_listed's job, asserted there against a session that stays
# up rather than here against one racing its own teardown.
# The start form now takes --block-cmd rules, which end up as arguments to a
# program run under sudo. Nothing reaches a shell, but the shape is checked
# before the rules are passed on, and a rejected start must start nothing.
test_start_rejects_bad_block_rule() {
    run_test "the start API refuses a malformed block rule"

    local before after body
    before="$(podman ps -q | wc -l)"
    body="$(web POST /api/sessions -H 'Content-Type: application/json' \
        -d "{\"agent\":\"claude\",\"dirs\":[\"${WORK_DIR}/proj\"],\"blocked\":[\"git; rm -rf /\"]}")"
    after="$(podman ps -q | wc -l)"

    if grep -q 'invalid block rule' <<<"$body" && [[ "$before" == "$after" ]]; then
        pass
    else
        fail "body=${body}"
    fi
}

test_web_session_labels() {
    run_test "ai-sandbox --web labels the container and gives the agent a TERM"

    local name="wtr$$" out="${STAGING}/ai-sandbox-start.log" probe="" labels="" envs="" i
    # Launched in the background and watched from the first moment, because the
    # agent here is `--version`: it prints and exits, and --rm then takes the
    # container away. ai-sandbox itself waits for the zellij session before it
    # returns, so inspecting after it returns loses that race every time -- the
    # old blind SKIP was this, not a slow machine.
    # TERM=dumb on purpose: that is what a systemd user service hands the web
    # dashboard, and propagating it would tell the agent it has no colours.
    env TERM=dumb "$AI_SANDBOX" "$TEST_AGENT" "$WORK_DIR" \
        --web --web-name "$name" --web-size 111x33 \
        --network-off --non-interactive -- --version >"$out" 2>&1 &
    local pid=$!

    # Labels and environment in one inspect: the container is racing its own
    # teardown, so a second call could find it already gone.
    for ((i = 0; i < 400; i++)); do
        probe="$(podman inspect --format \
            '{{index .Config.Labels "ai-sandbox.web"}}/{{index .Config.Labels "ai-sandbox.session"}}/{{index .Config.Labels "ai-sandbox.cols"}}|{{.Config.Env}}' \
            "sandbox-${name}" 2>/dev/null || true)"
        [[ -n "$probe" ]] && { labels="${probe%%|*}"; envs="${probe#*|}"; break; }
        # Nothing more is coming once ai-sandbox has exited without creating it.
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
    done

    wait "$pid" 2>/dev/null
    teardown_session "$name"

    # TERM is what tells the agent it has a terminal at all. zellij hands its
    # panes the environment of container PID 1, so if it is missing here the
    # agent renders in black and white however the client is attached.
    if [[ "$labels" == "1/${name}/111" ]] && grep -q "TERM=xterm" <<<"$envs"; then
        pass
    elif grep -qi "not set and running non-interactively" "$out" 2>/dev/null; then
        skip "no ${TEST_AGENT} credentials configured on this host"
    elif [[ -z "$labels" ]]; then
        # Never a bare skip: say what the script actually complained about.
        fail "no container: $(tr '\n' ' ' <"$out" | tail -c 160)"
    elif [[ "$labels" != "1/${name}/111" ]]; then
        fail "labels=${labels}"
    else
        fail "no usable TERM in the container environment: ${envs}"
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
    body="$(web GET /api/sessions || true)"
    if grep -q "wt1$$" <<<"$body" && grep -q '"cols": 100' <<<"$body"; then
        pass
    else
        fail "body=${body}"
    fi
}

# `ai-sandbox list` and the dashboard have to agree: both read the same opt-in
# label, and this suite only ever checked the dashboard's half. A listing that
# silently comes back empty -- a podman call whose failure nobody looked at --
# looks exactly like "no sessions running".
test_list_shows_web_session() {
    run_test "ai-sandbox list shows a running --web session"

    local name="wt1$$"
    if ! podman container exists "sandbox-${name}" 2>/dev/null; then
        skip "no session"
        return
    fi

    local out rc=0
    out="$("$AI_SANDBOX" list 2>&1)" || rc=$?
    if [[ $rc -eq 0 ]] && grep -q "$name" <<<"$out" && grep -q "100x30" <<<"$out"; then
        pass
    else
        fail "rc=${rc} out=$(tr '\n' ' ' <<<"$out" | tail -c 160)"
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
    # -it, not -i: a zellij client with no TTY does not attach at all, which
    # would make this test quietly measure one client instead of two.
    podman exec -it "sandbox-${name}" zellij attach "$name" >/dev/null 2>&1 &
    local pid_a=$!
    wait_for_clients "$name" atleast 1 >/dev/null

    # Client B: the browser, through the dashboard's own PTY.
    local attach_id
    attach_id="$(web POST "/api/sessions/${name}/attach" |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("attach_id",""))' 2>/dev/null || true)"
    if [[ -z "$attach_id" ]]; then
        fail "browser could not attach"
        kill "$pid_a" 2>/dev/null || true
        return
    fi

    curl -s -N -H "Authorization: Bearer ${TOKEN}" \
        "http://127.0.0.1:${WEB_PORT}/api/attach/${attach_id}/stream" >/dev/null 2>&1 &
    local pid_stream=$!

    local both
    both="$(wait_for_clients "$name" atleast 2)"

    # zellij sizes a shared session to its smallest client, so with a terminal
    # attached the browser may grow -- that shrinks nobody -- but must not
    # shrink, which would drag the terminal down with it. The session was made
    # at 100x30, so the first is a grow and the second a shrink.
    local grow shrink
    grow="$(status_of POST "/api/attach/${attach_id}/resize" \
        -H "Authorization: Bearer ${TOKEN}" -H 'X-AI-Sandbox: 1' \
        -H 'Content-Type: application/json' -d '{"cols":200,"rows":60}')"
    shrink="$(status_of POST "/api/attach/${attach_id}/resize" \
        -H "Authorization: Bearer ${TOKEN}" -H 'X-AI-Sandbox: 1' \
        -H 'Content-Type: application/json' -d '{"cols":60,"rows":20}')"

    # The dashboard has to notice the closed stream and tear its PTY down; that
    # is the phantom-client leak this whole test exists to catch, so wait for it
    # to happen rather than sampling once.
    kill "$pid_stream" 2>/dev/null || true
    local after_browser
    after_browser="$(wait_for_clients "$name" below "$both")"

    # Which side failed, if it did: 404 means the dashboard dropped the
    # attachment and the leftover client is inside the container, 200 means it
    # never noticed the browser go away at all.
    local dropped
    dropped="$(status_of GET "/api/attach/${attach_id}/stream" \
        -H "Authorization: Bearer ${TOKEN}" --max-time 2)"

    kill "$pid_a" 2>/dev/null || true
    sleep 2
    local alive="no"
    podman container exists "sandbox-${name}" 2>/dev/null && alive="yes"

    if [[ "$both" -ge 2 && "$grow" == 200 && "$shrink" == 409 &&
          "$after_browser" -lt "$both" && "$alive" == yes ]]; then
        pass
    else
        fail "clients=${both} grow=${grow} shrink=${shrink} after=${after_browser} alive=${alive} attachment=${dropped}"
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
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("attach_id",""))' 2>/dev/null || true)"
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
    accepted="$(web POST "/api/attach/${attach_id}/paste" --data-binary "@${png}" || true)"
    path="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("path",""))' \
            <<<"$accepted" 2>/dev/null || true)"

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

    # Networked on purpose: with --network=none this test would pass whatever
    # the dashboard does.
    local name="wt2$$"
    if ! start_web_session "$name" pasta; then
        skip "session did not start (is pasta available?)"
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

    # A throwaway HOME on purpose: with the real one, an existing ~/.claude (or
    # an env file) sends ai-sandbox down its "using OAuth session" fallback and
    # the guard under test is never reached.
    local fake_home rc=0
    fake_home="$(mktemp -d)"
    env -u ANTHROPIC_API_KEY HOME="$fake_home" timeout 30 "$AI_SANDBOX" claude "$WORK_DIR" \
        --web --web-name "wt3$$" </dev/null >/dev/null 2>&1 || rc=$?
    rm -rf "$fake_home"

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
# Fixtures for the completion test: a directory to find, one nested below it to
# prove the listing stops at one level, and one differing only in case.
mkdir -p "${WORK_DIR}/proj/nested" "${WORK_DIR}/CaseTest" "${WORK_DIR}/.secrets"
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
test_start_rejects_bad_block_rule
test_start_refuses_hidden_directory
test_dirs_completion
test_web_session_labels
test_web_session_listed
test_list_shows_web_session
test_dual_attach
test_paste_image
test_attach_refuses_non_web_container
test_invalid_session_name_rejected
test_container_cannot_reach_dashboard
test_session_cleanup
test_no_prompt_without_tty

echo ""
if [[ $FAIL -gt 0 && -s "${STAGING}/web.log" ]]; then
    # cleanup() removes $STAGING on exit, and the dashboard's own log is where
    # a podman or attach failure explains itself. Print it while it still exists.
    echo "--- dashboard log (last 20 lines) ---"
    tail -n 20 "${STAGING}/web.log"
    echo "-------------------------------------"
    echo ""
fi

echo "=============================="
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
