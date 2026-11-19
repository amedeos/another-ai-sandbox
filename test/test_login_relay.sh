#!/bin/bash
# =============================================================================
# test_login_relay.sh - ai-sandbox-login-relay without podman or Codex
#
# A fake `podman` stands in for both halves: `podman run` is the sign-in
# container (it waits until told to stop), and `podman exec -i CTR curl ...`
# runs the relay's curl against a fake Codex login server on another port.
# Needs python3 and curl; no root, no images.
#
# Usage: bash test/test_login_relay.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAY="${ROOT}/ai-sandbox-login-relay"
PORT=1455
FAKE_PORT=18455
WORK="$(mktemp -d)"
FAKE_PID=""
RELAY_PID=""
FAILED=0

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    [[ -n "$RELAY_PID" ]] && kill "$RELAY_PID" 2>/dev/null
    [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    local what="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        echo "PASS: ${what}"
    else
        echo "FAIL: ${what}: want '${want}', got '${got}'"
        FAILED=1
    fi
}

# Locally a busy port is a reason to skip; in CI it would mean the relay was
# never tested, so there it fails.
if curl -s -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then
    echo "SKIP: something already listens on 127.0.0.1:${PORT}"
    [[ -n "${CI:-}" ]] && exit 1
    exit 0
fi

# The routes of Codex's login server that the relay forwards.
cat > "${WORK}/fake_codex.py" <<PY
import http.server

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("${WORK}/codex.log", "a") as log:
            log.write(self.path + "\n")
        if self.path.startswith("/auth/callback"):
            self.send_response(302)
            self.send_header("Location", "http://localhost:${PORT}/success?id_token=a.b-c_d")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path.startswith("/success"):
            body = b"<html>Signed in</html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass

http.server.HTTPServer(("127.0.0.1", ${FAKE_PORT}), Handler).serve_forever()
PY

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/podman" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "${WORK}/argv.log"
if [[ "\$1" == run ]]; then
    for _ in \$(seq 1 300); do
        [[ -f "${WORK}/stop" ]] && exit 7
        sleep 0.1
    done
    exit 9
fi
[[ "\$1" == exec && "\$2" == -i ]] || exit 99
shift 3
config=\$(cat)
printf '%s\n' "\$config" | sed 's/127\.0\.0\.1:${PORT}/127.0.0.1:${FAKE_PORT}/' | "\$@"
status=\$?
# /success is Codex's last answer: the container exits and goes away while
# podman exec is still returning, so podman fails after curl has succeeded.
[[ "\$config" == *"/success"* ]] && exit 125
exit "\$status"
SH
chmod +x "${WORK}/bin/podman"

python3 "${WORK}/fake_codex.py" & FAKE_PID=$!
PATH="${WORK}/bin:${PATH}" python3 "$RELAY" --container sandbox-codex-login-test \
    -- podman run --rm -it IMAGE login 2>"${WORK}/relay.err" & RELAY_PID=$!

# Both must be up: the relay answers on its own port before the fake login
# server behind it has bound, and a callback forwarded too early gets a 502.
for port in "$PORT" "$FAKE_PORT"; do
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" && break
        sleep 0.1
    done
done

url="http://127.0.0.1:${PORT}/auth/callback?code=SECRETCODE&scope=openid+profile&state=s_t-8&iss=https%3A%2F%2Fauth.openai.com"
check "callback is answered with Codex's redirect" \
    "302 http://localhost:${PORT}/success?id_token=a.b-c_d" \
    "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$url")"
check "the browser, following it, reaches the success page (podman exits 125 there)" \
    "<html>Signed in</html>" "$(curl -s -L "$url")"
check "/cancel is not forwarded" "404" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/cancel")"
check "other paths are not forwarded" "404" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/etc/passwd")"
check "a quote in the query is not forwarded" "404" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/auth/callback?code=a\"b")"
check "a second relay finds the port taken" "3" \
    "$(PATH="${WORK}/bin:${PATH}" python3 "$RELAY" --container x -- true 2>/dev/null; echo $?)"

touch "${WORK}/stop"
status=0
wait "$RELAY_PID" || status=$?
RELAY_PID=""
check "the relay returns the sign-in container's status" "7" "$status"
check "the code never reaches a command line" "0" "$(grep -c SECRETCODE "${WORK}/argv.log" || true)"
check "the code never reaches the terminal" "0" "$(grep -c SECRETCODE "${WORK}/relay.err" || true)"
check "only callback and success reached the login server" "3" \
    "$(grep -c -E '^/(auth/callback|success)' "${WORK}/codex.log" || true)"

exit "$FAILED"
