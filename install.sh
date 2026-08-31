#!/bin/bash
# =============================================================================
# install.sh - Installs (or uninstalls) ai-sandbox
#
# Usage:
#   ./install.sh              # full install: script + images + BPF (if possible)
#   ./install.sh --no-build   # install script only, skip image build
#   ./install.sh --with-web   # install without asking about the web dashboard
#   ./install.sh --uninstall  # remove everything installed by this script
#
# Install:
#   1. Checks host prerequisites (podman, pasta, git, cgroups v2, python3)
#   2. Installs ai-sandbox and ai-sandbox-build to ~/.local/bin/
#   3. Copies Containerfiles/entrypoints to ~/.local/share/ai-sandbox/
#   4. Builds container images via ai-sandbox-build (unless --no-build)
#   5. Detects if BPF compilation is possible and builds the loader
#   6. Installs the web dashboard and its systemd user unit (optional)
#   7. Checks if ~/.local/bin is in PATH, offers to add it
#
# Uninstall:
#   Stops and removes the web dashboard unit, offers to remove any --web
#   sessions still running, removes ai-sandbox, ai-sandbox-build,
#   ai-sandbox-loader and ai-sandbox-web from ~/.local/bin, removes build data
#   from ~/.local/share/ai-sandbox/, optionally removes container images and
#   ~/.config/ai-sandbox, and cleans the PATH line added to the shell profile.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
DATA_DIR="${HOME}/.local/share/ai-sandbox"
WEB_DIR="${DATA_DIR}/web"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
WEB_UNIT="ai-sandbox-web.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INSTALL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# --- Argument parsing ---------------------------------------------------------
DO_BUILD=true
DO_UNINSTALL=false
DO_WEB=""          # empty = ask

for arg in "$@"; do
    case "$arg" in
        --no-build)  DO_BUILD=false ;;
        --uninstall) DO_UNINSTALL=true ;;
        --with-web)  DO_WEB=true ;;
        --no-web)    DO_WEB=false ;;
        -h|--help)
            echo "Usage: $0 [--no-build] [--with-web|--no-web] [--uninstall]"
            echo ""
            echo "  --no-build   Skip container image build"
            echo "  --with-web   Install the web dashboard without asking"
            echo "  --no-web     Skip the web dashboard"
            echo "  --uninstall  Remove ai-sandbox, BPF loader, images, and config"
            echo "  -h, --help   Show this help"
            exit 0
            ;;
        *)
            err "Unknown option: ${arg}"
            echo "Usage: $0 [--no-build] [--with-web|--no-web] [--uninstall]"
            exit 1
            ;;
    esac
done

# --- Host prerequisites -------------------------------------------------------
check_prerequisites() {
    local fatal=0

    echo -e "${CYAN}Checking prerequisites...${NC}"
    echo ""

    # podman (mandatory)
    if command -v podman >/dev/null 2>&1; then
        local podman_ver
        podman_ver="$(podman --version 2>/dev/null | head -1)"
        echo -e "  ${GREEN}✓${NC} podman  (${podman_ver})"
    else
        echo -e "  ${RED}✗${NC} podman — not found (required)"
        info "    Fedora:  dnf install podman"
        info "    Gentoo:  emerge -av app-containers/podman"
        info "    Debian:  apt install podman"
        fatal=1
    fi

    # pasta / passt (network backend, recommended)
    if command -v pasta >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} pasta   (network backend)"
    elif command -v passt >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} passt   (network backend — pasta alias expected)"
    else
        echo -e "  ${YELLOW}!${NC} pasta   — not found"
        warn "    pasta is the default network mode; without it you'll need to"
        warn "    change NETWORK_MODE to 'slirp4netns' in the ai-sandbox script"
        info "    Fedora:  dnf install passt"
        info "    Gentoo:  emerge -av net-misc/passt"
        info "    Debian:  apt install passt"
    fi

    # git (used to pass author/email into containers)
    if command -v git >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} git     ($(git --version 2>/dev/null | head -1))"
    else
        echo -e "  ${YELLOW}!${NC} git     — not found"
        warn "    git is recommended; ai-sandbox uses it to pass commit identity"
    fi

    # coreutils — realpath (used in ai-sandbox)
    if command -v realpath >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} realpath"
    else
        echo -e "  ${RED}✗${NC} realpath — not found (required, from coreutils)"
        fatal=1
    fi

    # cgroups v2
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        echo -e "  ${GREEN}✓${NC} cgroups v2"
    else
        echo -e "  ${YELLOW}!${NC} cgroups v2 — not detected"
        warn "    podman rootless requires cgroups v2; containers may not start"
    fi

    # sudo (needed for BPF, useful in general)
    if command -v sudo >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} sudo"
    else
        echo -e "  ${YELLOW}!${NC} sudo    — not found (needed only for BPF command blocking)"
    fi

    # python3 (the web dashboard; standard library only, no venv or pip)
    if command -v python3 >/dev/null 2>&1; then
        local pyver
        pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "?")"
        if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} python3 (${pyver})"
        else
            echo -e "  ${YELLOW}!${NC} python3 — ${pyver} is too old for the web dashboard (needs 3.9+)"
        fi
    else
        echo -e "  ${YELLOW}!${NC} python3 — not found (needed only for the web dashboard)"
        info "    Fedora: dnf install python3 / Gentoo: emerge dev-lang/python / Debian: apt install python3"
    fi

    # systemd user manager (the dashboard can also run in the foreground)
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} systemd --user"
    else
        echo -e "  ${YELLOW}!${NC} systemd --user — unavailable (run the dashboard with 'ai-sandbox web')"
    fi

    echo ""

    if [[ $fatal -ne 0 ]]; then
        err "Missing required dependencies — cannot continue"
        exit 1
    fi
}

# --- Install ai-sandbox script -----------------------------------------------
install_script() {
    log "Installing ai-sandbox to ${INSTALL_DIR}/"
    install -d "${INSTALL_DIR}"
    install -m 755 "${SCRIPT_DIR}/ai-sandbox" "${INSTALL_DIR}/ai-sandbox"
    install -m 755 "${SCRIPT_DIR}/ai-sandbox-build" "${INSTALL_DIR}/ai-sandbox-build"
    log "ai-sandbox and ai-sandbox-build installed successfully"
}

# --- Install build data (Containerfiles, entrypoints) ------------------------
install_build_data() {
    log "Installing build data to ${DATA_DIR}/"
    install -d "${DATA_DIR}"

    for component in base claude-code codex cursor-agent opencode; do
        local src="${SCRIPT_DIR}/${component}"
        local dst="${DATA_DIR}/${component}"
        if [[ ! -d "$src" ]]; then
            warn "Source directory not found: ${src} — skipping"
            continue
        fi
        install -d "${dst}"
        # Copy every file in the component directory, not just the two we used
        # to know about: base/ now also ships zellij.kdl and
        # ai-sandbox-supervise, and the next added file should not need a
        # change here.  Executables keep their mode so COPY lands them usable.
        local file
        for file in "${src}"/*; do
            [[ -f "$file" ]] || continue
            if [[ -x "$file" ]]; then
                install -m 755 "$file" "${dst}/$(basename "$file")"
            else
                install -m 644 "$file" "${dst}/$(basename "$file")"
            fi
        done
    done

    log "Build data installed successfully"
}

# --- Web dashboard ------------------------------------------------------------
verify_sha256() {
    local file="$1" expected="$2"
    echo "${expected}  ${file}" | sha256sum -c --status -
}

# The browser assets are fetched here rather than vendored into the repository,
# and pinned by content hash rather than trusted.  Serving them from disk is
# what lets the dashboard set Content-Security-Policy: default-src 'self' with
# no CDN at runtime.
fetch_web_assets() {
    local manifest="${SCRIPT_DIR}/web/assets.sha256"
    local sha dest url target tmp ok=true

    install -d "${WEB_DIR}/static/vendor"

    while read -r sha dest url; do
        [[ -z "${sha}" || "${sha}" == \#* ]] && continue
        target="${WEB_DIR}/static/${dest}"

        if [[ -f "$target" ]] && verify_sha256 "$target" "$sha"; then
            continue
        fi

        tmp="$(mktemp)"
        if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
            warn "Could not download $(basename "$dest") — no network?"
            rm -f "$tmp"
            ok=false
            continue
        fi
        if ! verify_sha256 "$tmp" "$sha"; then
            err "Checksum mismatch for ${url}"
            rm -f "$tmp"
            ok=false
            continue
        fi
        install -m 644 "$tmp" "$target"
        rm -f "$tmp"
    done < "$manifest"

    [[ "$ok" == true ]]
}

install_web() {
    log "Installing the web dashboard"

    install -m 755 "${SCRIPT_DIR}/web/ai-sandbox-web" "${INSTALL_DIR}/ai-sandbox-web"
    install -d "${WEB_DIR}/static"
    install -m 644 "${SCRIPT_DIR}"/web/static/*.html \
                   "${SCRIPT_DIR}"/web/static/*.css \
                   "${SCRIPT_DIR}"/web/static/*.js "${WEB_DIR}/static/"

    if ! fetch_web_assets; then
        warn "Browser assets are missing, so the dashboard will not render."
        warn "Re-run install.sh once you have network access."
        return 1
    fi

    install -d "${SYSTEMD_USER_DIR}"
    install -m 644 "${SCRIPT_DIR}/web/${WEB_UNIT}" "${SYSTEMD_USER_DIR}/${WEB_UNIT}"

    if command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null; then
        systemctl --user daemon-reload
        echo ""
        echo -en "  Enable and start the web dashboard now? [Y/n] "
        read -r answer
        case "$answer" in
            [nN]*)
                info "Skipped. Enable it later with:"
                info "  systemctl --user enable --now ${WEB_UNIT}"
                ;;
            *)
                if systemctl --user enable --now "${WEB_UNIT}"; then
                    log "Web dashboard running on http://127.0.0.1:8765"
                else
                    warn "Could not start ${WEB_UNIT}; see 'systemctl --user status ${WEB_UNIT}'"
                fi
                ;;
        esac
        info "Sessions and the dashboard stop at logout unless lingering is on:"
        info "  loginctl enable-linger \"\${USER}\""
    else
        warn "No systemd user manager here; run the dashboard in the foreground with:"
        warn "  ai-sandbox web"
    fi

    info "The access token is generated on first start in:"
    info "  ${HOME}/.config/ai-sandbox/web-token"
    info "Open http://127.0.0.1:8765/ and paste it, or use:"
    info "  xdg-open \"http://127.0.0.1:8765/?t=\$(cat ~/.config/ai-sandbox/web-token)\""
}

# --- Ensure host directories for agent configs exist -------------------------
ensure_host_dirs() {
    local sandbox_config="${HOME}/.config/ai-sandbox"
    if [[ ! -d "$sandbox_config" ]]; then
        log "Creating ${sandbox_config}/"
        install -d "$sandbox_config"
    fi

    local env_file="${sandbox_config}/env"
    if [[ ! -f "$env_file" ]]; then
        log "Creating ${env_file}"
        cat > "$env_file" <<'EOF'
# ai-sandbox environment — add your API keys here
# ANTHROPIC_API_KEY=sk-ant-...
# OPENAI_API_KEY=sk-...
# CURSOR_API_KEY=...
#
# Claude via Vertex AI
# CLAUDE_CODE_USE_VERTEX=1
# CLOUD_ML_REGION=global
# ANTHROPIC_VERTEX_PROJECT_ID=GCP_PROJECT_ID
#
# opencode — any OpenAI-compatible endpoint, Ollama Cloud by default
# (key for the default endpoint: https://ollama.com/settings/keys)
# AI_SANDBOX_OPENCODE_API_KEY=...
# AI_SANDBOX_OPENCODE_MODEL=glm-5.2:cloud
# AI_SANDBOX_OPENCODE_BASE_URL=https://ollama.com/v1
#
# Web dashboard (loopback only; see README "Web UI")
# AI_SANDBOX_WEB_ADDR=127.0.0.1
# AI_SANDBOX_WEB_PORT=8765
# Colon-separated roots a dashboard-started session may mount from ($HOME by default)
# AI_SANDBOX_WEB_ROOTS=/home/you/projects
EOF
        chmod 600 "$env_file"
    fi

    local vertex_dir="${sandbox_config}/claude-vertex"
    if [[ ! -d "$vertex_dir" ]]; then
        log "Creating ${vertex_dir}/"
        install -d "$vertex_dir"
    fi

    local vertex_json="${sandbox_config}/claude-vertex.json"
    if [[ ! -f "$vertex_json" ]]; then
        log "Creating ${vertex_json}"
        echo '{}' > "$vertex_json"
    fi

    local cursor_config="${HOME}/.config/cursor"
    if [[ ! -d "$cursor_config" ]]; then
        log "Creating ${cursor_config}/"
        install -d "$cursor_config"
    fi

    local cursor_dot="${HOME}/.cursor"
    if [[ ! -d "$cursor_dot" ]]; then
        log "Creating ${cursor_dot}/"
        install -d "$cursor_dot"
    fi
}

# --- Build container images ---------------------------------------------------
build_images() {
    log "Building container images (this may take a few minutes)..."
    echo ""
    if "${INSTALL_DIR}/ai-sandbox-build" all; then
        echo ""
        log "All container images built successfully"
    else
        echo ""
        err "Image build failed"
        err "You can retry later with: ai-sandbox --build all"
        return 1
    fi
}

# --- BPF build capability detection ------------------------------------------
can_build_bpf() {
    local missing=()

    command -v clang   >/dev/null 2>&1 || missing+=("clang")
    command -v bpftool >/dev/null 2>&1 || missing+=("bpftool")
    command -v gcc     >/dev/null 2>&1 || missing+=("gcc")

    # libbpf headers and library
    if command -v gcc >/dev/null 2>&1; then
        if ! echo '#include <bpf/libbpf.h>' | gcc -fsyntax-only -x c - 2>/dev/null; then
            missing+=("libbpf-devel")
        fi
        if ! echo '#include <libelf.h>' | gcc -fsyntax-only -x c - 2>/dev/null; then
            missing+=("elfutils-libelf-devel")
        fi
        if ! echo '#include <zlib.h>' | gcc -fsyntax-only -x c - 2>/dev/null; then
            missing+=("zlib-devel")
        fi
    fi

    # BTF info from running kernel
    if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
        missing+=("kernel BTF (CONFIG_DEBUG_INFO_BTF)")
    fi

    # BPF LSM support
    if [[ -f /sys/kernel/security/lsm ]]; then
        if ! grep -q 'bpf' /sys/kernel/security/lsm 2>/dev/null; then
            missing+=("BPF LSM (add 'bpf' to CONFIG_LSM)")
        fi
    else
        missing+=("LSM sysfs (kernel security module info)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Cannot build BPF loader — missing dependencies:"
        for dep in "${missing[@]}"; do
            echo -e "  ${RED}✗${NC} ${dep}"
        done
        echo ""
        info "Install hints:"
        info "  Fedora:        dnf install clang llvm libbpf-devel bpftool elfutils-libelf-devel zlib-devel"
        info "  Debian/Ubuntu: apt install clang llvm libbpf-dev linux-tools-common libelf-dev zlib1g-dev"
        info "  Gentoo:        emerge -av sys-devel/clang sys-devel/llvm dev-libs/libbpf sys-apps/bpftool dev-libs/elfutils sys-libs/zlib"
        return 1
    fi

    return 0
}

build_bpf() {
    log "Building BPF loader..."

    log "Running make clean in bpf/"
    make -C "${SCRIPT_DIR}/bpf" clean

    log "Building BPF program and loader..."
    if make -C "${SCRIPT_DIR}/bpf" LOADER_DIR="${INSTALL_DIR}"; then
        log "BPF loader installed to ${INSTALL_DIR}/ai-sandbox-loader"
        return 0
    else
        err "BPF build failed"
        return 1
    fi
}

# --- PATH check --------------------------------------------------------------
check_path() {
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*)
            return 0
            ;;
    esac
    return 1
}

detect_shell_profile() {
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"

    case "$shell_name" in
        bash)
            if [[ -f "${HOME}/.bash_profile" ]]; then
                echo "${HOME}/.bash_profile"
            elif [[ -f "${HOME}/.bash_login" ]]; then
                echo "${HOME}/.bash_login"
            else
                echo "${HOME}/.profile"
            fi
            ;;
        zsh)
            echo "${HOME}/.zshrc"
            ;;
        fish)
            echo "${HOME}/.config/fish/config.fish"
            ;;
        *)
            echo "${HOME}/.profile"
            ;;
    esac
}

add_to_path() {
    local profile
    profile="$(detect_shell_profile)"
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"

    if [[ "$shell_name" == "fish" ]]; then
        local line="fish_add_path ${INSTALL_DIR}"
    else
        local line="export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    fi

    # Avoid duplicate entries
    if [[ -f "$profile" ]] && grep -qF '.local/bin' "$profile" 2>/dev/null; then
        info "${profile} already references .local/bin — skipping"
        return 0
    fi

    {
        echo ""
        echo "# Added by ai-sandbox install.sh"
        echo "$line"
    } >> "$profile"
    log "Added ${INSTALL_DIR} to PATH in ${profile}"
    info "Run 'source ${profile}' or open a new terminal to use ai-sandbox"
}

offer_path_fix() {
    warn "${INSTALL_DIR} is NOT in your current PATH"
    echo ""
    local profile
    profile="$(detect_shell_profile)"
    echo -en "  Add it to ${CYAN}${profile}${NC}? [Y/n] "
    read -r answer
    case "$answer" in
        [nN]*)
            info "Skipped. Add it manually:"
            info "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
            ;;
        *)
            add_to_path
            ;;
    esac
}

# --- Uninstall ----------------------------------------------------------------
do_uninstall() {
    echo ""
    echo -e "${CYAN}ai-sandbox uninstaller${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local removed=0

    # 1. Stop and remove the web dashboard service.
    #    Done first so nothing is holding attachments open while the rest goes.
    if [[ -f "${SYSTEMD_USER_DIR}/${WEB_UNIT}" ]]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment &>/dev/null; then
            systemctl --user disable --now "${WEB_UNIT}" >/dev/null 2>&1 || true
        fi
        rm -f "${SYSTEMD_USER_DIR}/${WEB_UNIT}"
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment &>/dev/null; then
            systemctl --user daemon-reload >/dev/null 2>&1 || true
        fi
        log "Removed and disabled ${WEB_UNIT}"
        removed=1
    fi

    # 2. Offer to remove leftover web sessions.
    #    Only --web sessions can outlive the shell that started them, so this is
    #    the one place an uninstall can leave containers running.
    if command -v podman >/dev/null 2>&1; then
        local -a web_sessions
        mapfile -t web_sessions < <(podman ps -a --filter label=ai-sandbox.web=1 \
            --format '{{index .Labels "ai-sandbox.session"}}' 2>/dev/null || true)
        if [[ ${#web_sessions[@]} -gt 0 ]]; then
            echo ""
            info "These sandbox sessions are still present:"
            printf '    %s\n' "${web_sessions[@]}"
            echo -en "\n  Remove them? [y/N] "
            read -r answer
            if [[ "$answer" =~ ^[yY]$ ]]; then
                local ids
                mapfile -t ids < <(podman ps -a --filter label=ai-sandbox.web=1 -q)
                podman rm -f "${ids[@]}" >/dev/null 2>&1 || true
                log "Removed leftover sandbox sessions"
                removed=1
            else
                info "Left running — stop them later with: podman rm -f <name>"
            fi
        fi
    fi

    # 3. Remove binaries from ~/.local/bin
    if [[ -f "${INSTALL_DIR}/ai-sandbox" ]]; then
        rm -f "${INSTALL_DIR}/ai-sandbox"
        log "Removed ${INSTALL_DIR}/ai-sandbox"
        removed=1
    else
        info "ai-sandbox not found in ${INSTALL_DIR} — skipping"
    fi

    if [[ -f "${INSTALL_DIR}/ai-sandbox-build" ]]; then
        rm -f "${INSTALL_DIR}/ai-sandbox-build"
        log "Removed ${INSTALL_DIR}/ai-sandbox-build"
        removed=1
    fi

    if [[ -f "${INSTALL_DIR}/ai-sandbox-loader" ]]; then
        rm -f "${INSTALL_DIR}/ai-sandbox-loader"
        log "Removed ${INSTALL_DIR}/ai-sandbox-loader"
        removed=1
    fi

    if [[ -f "${INSTALL_DIR}/ai-sandbox-web" ]]; then
        rm -f "${INSTALL_DIR}/ai-sandbox-web"
        log "Removed ${INSTALL_DIR}/ai-sandbox-web"
        removed=1
    fi

    # 4. Remove build data from ~/.local/share/ai-sandbox
    if [[ -d "${DATA_DIR}" ]]; then
        rm -rf "${DATA_DIR}"
        log "Removed ${DATA_DIR}"
        removed=1
    fi

    # 5. Container images
    if command -v podman >/dev/null 2>&1; then
        local images=()
        for img in agent-base agent-claude agent-codex agent-cursor agent-opencode; do
            if podman image exists "localhost/${img}:latest" 2>/dev/null; then
                images+=("localhost/${img}:latest")
            fi
        done

        if [[ ${#images[@]} -gt 0 ]]; then
            echo ""
            warn "Found ${#images[@]} container image(s):"
            for img in "${images[@]}"; do
                echo -e "  - ${img}"
            done
            echo -en "\n  Remove them? [y/N] "
            read -r answer
            if [[ "$answer" =~ ^[yY]$ ]]; then
                for img in "${images[@]}"; do
                    podman rmi -f "$img" 2>/dev/null && log "Removed image ${img}"
                done
                removed=1
            else
                info "Keeping container images"
            fi
        fi
    fi

    # 6. Config directory
    if [[ -d "${HOME}/.config/ai-sandbox" ]]; then
        echo ""
        warn "Found config directory: ~/.config/ai-sandbox/"
        echo -en "  Remove it? [y/N] "
        read -r answer
        if [[ "$answer" =~ ^[yY]$ ]]; then
            rm -rf "${HOME}/.config/ai-sandbox"
            log "Removed ~/.config/ai-sandbox/"
            removed=1
        else
            info "Keeping ~/.config/ai-sandbox/"
        fi
    fi

    # 7. Clean PATH line from shell profile
    local profile
    profile="$(detect_shell_profile)"
    if [[ -f "$profile" ]] && grep -qF '# Added by ai-sandbox install.sh' "$profile" 2>/dev/null; then
        echo ""
        warn "Found ai-sandbox PATH entry in ${profile}"
        echo -en "  Remove it? [Y/n] "
        read -r answer
        case "$answer" in
            [nN]*)
                info "Keeping PATH entry in ${profile}"
                ;;
            *)
                # Remove the comment line and the line immediately after it
                local tmp
                tmp="$(mktemp)"
                awk '
                    /^# Added by ai-sandbox install.sh$/ { skip=1; next }
                    skip { skip=0; next }
                    { print }
                ' "$profile" > "$tmp"
                mv "$tmp" "$profile"
                log "Removed ai-sandbox PATH entry from ${profile}"
                removed=1
                ;;
        esac
    fi

    echo ""
    if [[ $removed -eq 1 ]]; then
        log "Uninstall complete"
    else
        info "Nothing to remove — ai-sandbox was not installed"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================

if [[ "$DO_UNINSTALL" == true ]]; then
    do_uninstall
    exit 0
fi

echo ""
echo -e "${CYAN}ai-sandbox installer${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Check host prerequisites
check_prerequisites

# 2. Install the main script and build data
install_script
install_build_data
ensure_host_dirs
echo ""

# 3. Build container images (unless --no-build)
if [[ "$DO_BUILD" == true ]]; then
    build_images
    echo ""
else
    info "Skipping container image build (--no-build)"
    info "Run 'ai-sandbox --build all' later to build the images"
    echo ""
fi

# 4. BPF loader
if can_build_bpf; then
    echo ""
    echo -en "  Build and install the BPF command blocker? [Y/n] "
    read -r bpf_answer
    case "$bpf_answer" in
        [nN]*)
            info "Skipping BPF build"
            ;;
        *)
            echo ""
            build_bpf
            ;;
    esac
else
    echo ""
    info "BPF command blocker will not be built (optional feature)"
    info "ai-sandbox works fine without it — you just won't be able to use --block-cmd"
fi
echo ""

# 5. Web dashboard
if [[ -z "$DO_WEB" ]]; then
    if [[ -t 0 ]] && command -v python3 >/dev/null 2>&1; then
        echo -en "  Install the web dashboard (browser access to sessions)? [Y/n] "
        read -r web_answer
        case "$web_answer" in
            [nN]*) DO_WEB=false ;;
            *)     DO_WEB=true ;;
        esac
    else
        DO_WEB=false
    fi
fi

if [[ "$DO_WEB" == true ]]; then
    if command -v python3 >/dev/null 2>&1; then
        echo ""
        install_web || true
    else
        warn "Skipping the web dashboard: python3 is not installed"
    fi
else
    info "Web dashboard not installed — add it later with: ./install.sh --with-web"
fi
echo ""

# 6. PATH check
if ! check_path; then
    offer_path_fix
fi
echo ""

log "Installation complete!"
echo ""
if [[ "$DO_BUILD" == true ]]; then
    info "Next steps:"
    info "  1. Configure API keys:  vi ~/.config/ai-sandbox/env"
    info "  2. Run:                 ai-sandbox claude ~/my-project"
else
    info "Next steps:"
    info "  1. Build container images:  ai-sandbox --build all"
    info "  2. Configure API keys:      vi ~/.config/ai-sandbox/env"
    info "  3. Run:                      ai-sandbox claude ~/my-project"
fi
echo ""
