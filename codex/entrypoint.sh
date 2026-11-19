#!/bin/bash
# Prepare home directories on tmpfs before starting Codex CLI
set -euo pipefail

mkdir -p ~/.cache ~/.config

args=()

# Codex's background server is for sharing one long-lived process between
# sessions; a container has nothing to share it with.  Started here, it would
# copy a ~370 MB package into the sandbox's Codex home (~/.codex, bind-mounted
# from ~/.config/ai-sandbox/codex by ai-sandbox) and leave a self-updater
# running inside the sandbox.
#
# --no-daemon arrived in Codex 0.156 together with the server itself; older
# releases reject it as an unknown argument.  The image's npm layer is cached
# across rebuilds and can be older than this script, so pass the flag only when
# this codex lists it, as a whole option: a longer flag that merely contains the
# name must not count.  The help text is captured rather than piped into
# `grep -q`, which can exit early and fail the pipeline under pipefail.  Not
# when the user passes it too, as Codex's own failure hint tells them to: a
# repeated --no-daemon is a usage error.  Should the probe ever miss, current
# releases still keep off the server for the -c override below, since any -c
# other than a feature toggle rules it out (tui/src/daemon_startup.rs).
user_no_daemon=false
for arg in "$@"; do
    [[ "$arg" == --no-daemon ]] && user_no_daemon=true
done
help_text="$(codex --help 2>/dev/null || true)"
if [[ "$user_no_daemon" == false && "$help_text" =~ (^|[[:space:],])--no-daemon([[:space:],=]|$) ]]; then
    args+=(--no-daemon)
fi

# Codex's own sandbox (bubblewrap + seccomp) cannot create its namespaces under
# the container's --cap-drop=ALL and no-new-privileges.  The container is the
# boundary, which is the case Codex's documentation prescribes
# danger-full-access for.  As a -c override it reaches every subcommand, and an
# explicit --sandbox from the user still wins.  The value is left unquoted:
# Codex takes a value that does not parse as TOML as a plain string.
args+=(-c sandbox_mode=danger-full-access)

# Both go before "$@": they are options of the top-level command, and after a
# subcommand (`login status`, `exec "..."`) Codex rejects them.
exec ai-sandbox-supervise codex "${args[@]}" "$@"
