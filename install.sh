#!/usr/bin/env bash
# github-agent installer / manager
# Usage: curl -fsSL https://raw.githubusercontent.com/prlima/agent-updater/main/install.sh | sudo bash
set -euo pipefail

REPO="prlima/agent-updater"
AGENT_USER="github-agent"
AGENT_GROUP="github-agent"
CONFIG_DIR="/etc/github-agent"
LOG_DIR="/var/log/github-agent"
BINARY_PATH="/usr/local/bin/github-agent"
SERVICE_PATH="/etc/systemd/system/github-agent.service"
SUDOERS_PATH="/etc/sudoers.d/github-agent"

# ── Colors ───────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()   { echo -e "${B}  →${NC} $*"; }
ok()     { echo -e "${G}  ✓${NC} $*"; }
warn()   { echo -e "${Y}  !${NC} $*"; }
die()    { echo -e "${R}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${B}▶ $*${NC}"; echo -e "${B}$(printf '%.0s─' {1..50})${NC}"; }
ask()    { printf "${Y}  ? %s${NC} " "$*"; }
sep()    { echo -e "${B}  $(printf '%.0s─' {1..50})${NC}"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: curl ... | sudo bash"
[[ $(uname -s) == "Linux" ]] || die "Linux only."

command -v curl    &>/dev/null || die "'curl' required but not found."
command -v openssl &>/dev/null || die "'openssl' required but not found."

echo ""
echo -e "${BOLD}  github-agent installer${NC}"
echo -e "  repo: github.com/${REPO}"
echo ""

# ── Menu (already installed) ──────────────────────────────────────────────────
# Piped as `curl | sudo bash`, so every `read` below pulls from /dev/tty
# directly — stdin itself is the script body, not the terminal.
ALREADY_INSTALLED=0
[[ -f "$BINARY_PATH" && -f "$CONFIG_DIR/config.yaml" ]] && ALREADY_INSTALLED=1

DO_DOWNLOAD=1
RECONFIGURE=1
ADD_PROJECT_ONLY=0

if [[ "$ALREADY_INSTALLED" -eq 1 ]]; then
    STATUS=$(systemctl is-active github-agent 2>/dev/null || echo "inactive")
    CURRENT_VERSION=$("$BINARY_PATH" -version 2>/dev/null || echo "unknown")

    echo -e "  Status: ${BOLD}${STATUS}${NC}   Version: ${BOLD}${CURRENT_VERSION}${NC}"
    echo ""
    echo -e "  ${BOLD}What do you want to do?${NC}"
    echo ""
    echo "   1) View current config"
    echo "   2) Edit config (opens editor)"
    echo "   3) View webhook secret"
    echo "   4) Add project"
    echo "   5) Restart service"
    echo "   6) View logs (last 50 lines)"
    echo "   7) Update binary"
    echo "   8) Reconfigure everything"
    echo "   9) Uninstall"
    echo "   0) Exit"
    echo ""
    ask "Option:"
    read -r OPT < /dev/tty

    case "$OPT" in
      1)
        echo ""
        sep
        cat "$CONFIG_DIR/config.yaml"
        sep
        echo ""
        exit 0
        ;;
      2)
        EDITOR="${EDITOR:-vi}"
        "$EDITOR" "$CONFIG_DIR/config.yaml" < /dev/tty > /dev/tty
        echo ""
        ask "Restart service to apply? [Y/n]:"
        read -r ans < /dev/tty
        [[ "${ans,,}" =~ ^(n|no)$ ]] || { systemctl restart github-agent && ok "Service restarted."; }
        exit 0
        ;;
      3)
        echo ""
        SECRET=$(grep GITHUB_WEBHOOK_SECRET "$CONFIG_DIR/env" | cut -d= -f2-)
        echo -e "  ${BOLD}GITHUB_WEBHOOK_SECRET:${NC}"
        echo ""
        echo -e "    ${G}${BOLD}${SECRET}${NC}"
        echo ""
        exit 0
        ;;
      4)
        ADD_PROJECT_ONLY=1
        DO_DOWNLOAD=0
        RECONFIGURE=0
        ;;
      5)
        systemctl restart github-agent
        sleep 1
        systemctl is-active --quiet github-agent && ok "Service restarted." || warn "Failed to restart."
        exit 0
        ;;
      6)
        echo ""
        journalctl -u github-agent -n 50 --no-pager
        exit 0
        ;;
      7)
        DO_DOWNLOAD=1
        RECONFIGURE=0
        ADD_PROJECT_ONLY=0
        ;;
      8)
        DO_DOWNLOAD=1
        RECONFIGURE=1
        ADD_PROJECT_ONLY=0
        ;;
      9)
        echo ""
        warn "This will remove the service, binary, config and sudoers rule."
        ask "Confirm uninstall? [y/N]:"
        read -r ans < /dev/tty
        [[ "${ans,,}" =~ ^(y|yes)$ ]] || { info "Cancelled."; exit 0; }
        echo ""
        systemctl stop github-agent    2>/dev/null && info "Service stopped."   || true
        systemctl disable github-agent 2>/dev/null && info "Service disabled." || true
        rm -f "$SERVICE_PATH"
        systemctl daemon-reload
        rm -f "$BINARY_PATH"
        rm -rf "$CONFIG_DIR"
        rm -f "$SUDOERS_PATH"
        ok "github-agent uninstalled."
        echo ""
        warn "Log directory kept: $LOG_DIR"
        ask "Remove logs too? [y/N]:"
        read -r ans < /dev/tty
        [[ "${ans,,}" =~ ^(y|yes)$ ]] && { rm -rf "$LOG_DIR"; ok "Logs removed."; } || true
        exit 0
        ;;
      0)
        exit 0
        ;;
      *)
        die "Invalid option."
        ;;
    esac
fi

# ── Download & install binary ─────────────────────────────────────────────────
if [[ "$DO_DOWNLOAD" -eq 1 ]]; then
    header "System"
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  GOARCH="amd64" ;;
      aarch64) GOARCH="arm64" ;;
      *) die "Unsupported architecture: $ARCH" ;;
    esac
    ok "Architecture: $ARCH → $GOARCH"

    header "Fetching latest release"
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    info "Querying $API_URL..."

    RELEASE_JSON=$(curl -fsSL "$API_URL") || die "Failed to reach GitHub API. Check network or that a release exists."
    TAG=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    [[ -n "$TAG" ]] || die "Could not determine latest release tag."

    ok "Latest release: $TAG"

    BINARY_NAME="github-agent-linux-${GOARCH}"
    DOWNLOAD_BASE="https://github.com/${REPO}/releases/download/${TAG}"

    header "Downloading binary"
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    info "Downloading $BINARY_NAME..."
    curl -fsSL "${DOWNLOAD_BASE}/${BINARY_NAME}" -o "${TMP_DIR}/${BINARY_NAME}"

    info "Downloading checksums.txt..."
    curl -fsSL "${DOWNLOAD_BASE}/checksums.txt" -o "${TMP_DIR}/checksums.txt"

    info "Verifying SHA256..."
    (cd "$TMP_DIR" && grep "$BINARY_NAME" checksums.txt | sha256sum -c -) || die "Checksum mismatch — aborting."
    ok "Checksum verified."

    install -m 755 -o root -g root "${TMP_DIR}/${BINARY_NAME}" "$BINARY_PATH"
    ok "Binary installed: $BINARY_PATH ($TAG)"
fi

# "Update binary" (menu option 7) stops here — nothing else changed.
if [[ "$RECONFIGURE" -eq 0 && "$ADD_PROJECT_ONLY" -eq 0 ]]; then
    systemctl restart github-agent
    sleep 1
    systemctl is-active --quiet github-agent && ok "Service restarted." || warn "Failed to restart."
    exit 0
fi

# ── System user ───────────────────────────────────────────────────────────────
header "System user"

if ! getent group "$AGENT_GROUP" &>/dev/null; then
    groupadd --system "$AGENT_GROUP"
    ok "Group $AGENT_GROUP created."
else
    ok "Group $AGENT_GROUP exists."
fi

if ! id "$AGENT_USER" &>/dev/null; then
    useradd --system --gid "$AGENT_GROUP" \
        --no-create-home --shell /usr/sbin/nologin "$AGENT_USER"
    ok "User $AGENT_USER created."
else
    ok "User $AGENT_USER exists."
fi

# ── Directories ───────────────────────────────────────────────────────────────
header "Directories"

mkdir -p "$CONFIG_DIR" "$LOG_DIR"
chown root:root "$CONFIG_DIR"; chmod 750 "$CONFIG_DIR"
chown "$AGENT_USER:$AGENT_GROUP" "$LOG_DIR"; chmod 755 "$LOG_DIR"
ok "Directories ready."

# ── Add project only (menu option 4) ──────────────────────────────────────────
if [[ "$ADD_PROJECT_ONLY" -eq 1 ]]; then
    header "Add project"
    echo ""

    ask "GitHub repo (owner/repo):"
    read -r REPO_NAME < /dev/tty
    [[ "$REPO_NAME" =~ ^[^/]+/[^/]+$ ]] || die "Invalid format. Use owner/repo."

    ask "Branch [main]:"
    read -r REPO_BRANCH < /dev/tty
    REPO_BRANCH="${REPO_BRANCH:-main}"

    ask "Workflow file (e.g. deploy.yml) — blank = any:"
    read -r REPO_WORKFLOW < /dev/tty

    ask "Absolute project path on this server (e.g. /home/deploy/projects/myapp):"
    read -r DEPLOY_PATH < /dev/tty
    [[ "$DEPLOY_PATH" == /* ]] || die "Path must be absolute."
    DEPLOY_PATH="$(realpath -m "$DEPLOY_PATH")"

    ask "OS user that owns the project (e.g. deploy):"
    read -r DEPLOY_USER < /dev/tty
    [[ -n "$DEPLOY_USER" ]] || die "deploy_user cannot be empty."
    id "$DEPLOY_USER" &>/dev/null || die "User '$DEPLOY_USER' does not exist."

    ask "Deploy script filename inside $DEPLOY_PATH [update.sh]:"
    read -r DEPLOY_SCRIPT < /dev/tty
    DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-update.sh}"
    [[ "$DEPLOY_SCRIPT" != */* ]] || die "deploy_script must be a filename, not a path."

    NEW_ENTRY="  - name: \"${REPO_NAME}\"\n    branch: \"${REPO_BRANCH}\"\n"
    [[ -n "$REPO_WORKFLOW" ]] && NEW_ENTRY+="    workflow: \"${REPO_WORKFLOW}\"\n"
    NEW_ENTRY+="    deploy_path: \"${DEPLOY_PATH}\"\n    deploy_user: \"${DEPLOY_USER}\"\n    deploy_script: \"${DEPLOY_SCRIPT}\""

    printf '\n%b\n' "$NEW_ENTRY" >> "$CONFIG_DIR/config.yaml"
    ok "Project added to config.yaml."

    SCRIPT_FULL="${DEPLOY_PATH}/${DEPLOY_SCRIPT}"
    SUDOERS_LINE="$AGENT_USER ALL=(${DEPLOY_USER}) NOPASSWD: ${SCRIPT_FULL}"
    if ! grep -qF "$SUDOERS_LINE" "$SUDOERS_PATH" 2>/dev/null; then
        { echo ""; echo "# Project: $SCRIPT_FULL"; echo "$SUDOERS_LINE"; } >> "$SUDOERS_PATH"
        chmod 0440 "$SUDOERS_PATH"
        command -v visudo &>/dev/null && visudo -c -f "$SUDOERS_PATH" || die "sudoers syntax error."
        ok "sudoers updated."
    fi

    systemctl restart github-agent
    sleep 1
    systemctl is-active --quiet github-agent && ok "Service restarted." || warn "Failed to restart."
    exit 0
fi

# ── Configuration wizard (fresh install or full reconfigure) ─────────────────
header "Configuration wizard"

# ── Server settings ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Server${NC}"

ask "Listening port [9000]:"
read -r PORT < /dev/tty
PORT="${PORT:-9000}"
[[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1024 && "$PORT" -le 65535 ]] || die "Invalid port: $PORT"

ask "Webhook path [/webhook]:"
read -r WH_PATH < /dev/tty
WH_PATH="${WH_PATH:-/webhook}"
[[ "$WH_PATH" == /* ]] || WH_PATH="/$WH_PATH"

# ── Webhook secret ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Webhook secret${NC}"
echo "  Used to verify requests come from GitHub."
echo ""

ask "Generate random secret? [Y/n]:"
read -r ans < /dev/tty
if [[ "${ans,,}" =~ ^(n|no)$ ]]; then
    ask "Enter secret (min 20 chars):"
    read -rs WEBHOOK_SECRET < /dev/tty; echo ""
    [[ ${#WEBHOOK_SECRET} -ge 20 ]] || die "Secret too short."
else
    WEBHOOK_SECRET="$(openssl rand -hex 32)"
    echo ""
    echo -e "  ${BOLD}Generated secret (copy now — shown once):${NC}"
    echo ""
    echo -e "    ${G}${BOLD}${WEBHOOK_SECRET}${NC}"
    echo ""
    echo "  Paste this into: GitHub → Repo → Settings → Webhooks → Secret"
    echo ""
    ask "Press Enter when saved..."
    read -r _ < /dev/tty
fi

# ── Repos ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Projects${NC}"
echo "  Each project = one GitHub repo that triggers a deploy script."
echo ""

REPOS_YAML=""
declare -A SUDOERS_ENTRIES
REPO_INDEX=0

while true; do
    REPO_INDEX=$((REPO_INDEX + 1))
    echo -e "  ${BOLD}Project #${REPO_INDEX}${NC}"

    ask "GitHub repo (owner/repo):"
    read -r REPO_NAME < /dev/tty
    [[ "$REPO_NAME" =~ ^[^/]+/[^/]+$ ]] || die "Invalid format. Use owner/repo."

    ask "Branch [main]:"
    read -r REPO_BRANCH < /dev/tty
    REPO_BRANCH="${REPO_BRANCH:-main}"

    ask "Workflow file (e.g. deploy.yml) — blank = any:"
    read -r REPO_WORKFLOW < /dev/tty

    ask "Absolute project path on this server (e.g. /home/deploy/projects/myapp):"
    read -r DEPLOY_PATH < /dev/tty
    [[ "$DEPLOY_PATH" == /* ]] || die "Path must be absolute."
    DEPLOY_PATH="$(realpath -m "$DEPLOY_PATH")"

    ask "OS user that owns the project (e.g. deploy):"
    read -r DEPLOY_USER < /dev/tty
    [[ -n "$DEPLOY_USER" ]] || die "deploy_user cannot be empty."

    if ! id "$DEPLOY_USER" &>/dev/null; then
        warn "User '$DEPLOY_USER' does not exist."
        ask "Create system user '$DEPLOY_USER'? [Y/n]:"
        read -r ans < /dev/tty
        if [[ ! "${ans,,}" =~ ^(n|no)$ ]]; then
            useradd --system --no-create-home --shell /usr/sbin/nologin "$DEPLOY_USER" || true
            ok "User $DEPLOY_USER created."
        fi
    fi

    ask "Deploy script filename inside $DEPLOY_PATH [update.sh]:"
    read -r DEPLOY_SCRIPT < /dev/tty
    DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-update.sh}"
    [[ "$DEPLOY_SCRIPT" != */* ]] || die "deploy_script must be a filename, not a path."

    # Append to YAML
    REPOS_YAML+="  - name: \"${REPO_NAME}\"\n"
    REPOS_YAML+="    branch: \"${REPO_BRANCH}\"\n"
    [[ -n "$REPO_WORKFLOW" ]] && REPOS_YAML+="    workflow: \"${REPO_WORKFLOW}\"\n"
    REPOS_YAML+="    deploy_path: \"${DEPLOY_PATH}\"\n"
    REPOS_YAML+="    deploy_user: \"${DEPLOY_USER}\"\n"
    REPOS_YAML+="    deploy_script: \"${DEPLOY_SCRIPT}\"\n\n"

    # Track sudoers entry
    SCRIPT_FULL="${DEPLOY_PATH}/${DEPLOY_SCRIPT}"
    SUDOERS_ENTRIES["${DEPLOY_USER}|${SCRIPT_FULL}"]="1"

    echo ""
    ask "Add another project? [y/N]:"
    read -r ans < /dev/tty
    [[ "${ans,,}" =~ ^(y|yes)$ ]] || break
    echo ""
done

# ── Write config.yaml ─────────────────────────────────────────────────────
info "Writing $CONFIG_DIR/config.yaml..."

cat > "$CONFIG_DIR/config.yaml" <<YAML
server:
  addr: "127.0.0.1:${PORT}"
  read_timeout_seconds: 10
  write_timeout_seconds: 10
  max_body_bytes: 10485760

webhook:
  path: "${WH_PATH}"
  secret: "\${GITHUB_WEBHOOK_SECRET}"

repos:
$(printf '%b' "$REPOS_YAML")
YAML

chmod 0640 "$CONFIG_DIR/config.yaml"
chown root:"$AGENT_GROUP" "$CONFIG_DIR/config.yaml"
ok "config.yaml written."

# ── Write env ─────────────────────────────────────────────────────────────
info "Writing $CONFIG_DIR/env..."

printf 'GITHUB_WEBHOOK_SECRET=%s\n' "$WEBHOOK_SECRET" > "$CONFIG_DIR/env"
chmod 0600 "$CONFIG_DIR/env"
chown "$AGENT_USER:$AGENT_GROUP" "$CONFIG_DIR/env"
ok "env written."

# ── sudoers ───────────────────────────────────────────────────────────────
info "Writing $SUDOERS_PATH..."

{
    echo "# github-agent — generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    for key in "${!SUDOERS_ENTRIES[@]}"; do
        deploy_user="${key%%|*}"
        script_path="${key##*|}"
        echo "# Project: $script_path"
        echo "$AGENT_USER ALL=(${deploy_user}) NOPASSWD: ${script_path}"
        echo ""
    done
} > "$SUDOERS_PATH"

chmod 0440 "$SUDOERS_PATH"
chown root:root "$SUDOERS_PATH"

command -v visudo &>/dev/null && visudo -c -f "$SUDOERS_PATH" || die "sudoers syntax error."
ok "sudoers written."

# ── systemd service ───────────────────────────────────────────────────────────
header "systemd service"

cat > "$SERVICE_PATH" <<SERVICE
[Unit]
Description=GitHub Actions Webhook Deploy Agent
After=network.target
Wants=network.target

[Service]
Type=simple
User=${AGENT_USER}
Group=${AGENT_GROUP}

EnvironmentFile=${CONFIG_DIR}/env
ExecStart=${BINARY_PATH} -config ${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=5s

ReadWritePaths=${LOG_DIR}
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=false
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
PrivateTmp=true
ProtectKernelModules=true
ProtectKernelTunables=true

StandardOutput=append:${LOG_DIR}/agent.log
StandardError=append:${LOG_DIR}/agent.log

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 "$SERVICE_PATH"
ok "Service file written."

systemctl daemon-reload
systemctl enable github-agent
systemctl restart github-agent

sleep 2
systemctl is-active --quiet github-agent \
    && ok "github-agent is running." \
    || warn "Service may not have started. Check: journalctl -u github-agent -n 30"

# ── Summary ───────────────────────────────────────────────────────────────────
PORT_USED=$(grep -oP '(?<=addr: "127\.0\.0\.1:)\d+' "$CONFIG_DIR/config.yaml" 2>/dev/null || echo "9000")
WH_USED=$(grep -oP '(?<=path: ").*(?=")' "$CONFIG_DIR/config.yaml" 2>/dev/null | head -1 || echo "/webhook")

echo ""
echo -e "${BOLD}${G}  Installation complete ✓${NC}"
echo ""
echo -e "  ${BOLD}Version:${NC}   $TAG"
echo -e "  ${BOLD}Binary:${NC}    $BINARY_PATH"
echo -e "  ${BOLD}Config:${NC}    $CONFIG_DIR/config.yaml"
echo -e "  ${BOLD}Env:${NC}       $CONFIG_DIR/env"
echo -e "  ${BOLD}Sudoers:${NC}   $SUDOERS_PATH"
echo -e "  ${BOLD}Logs:${NC}      $LOG_DIR/agent.log"
echo ""
echo -e "  ${BOLD}Endpoint:${NC}  http://127.0.0.1:${PORT_USED}${WH_USED}"
echo -e "  ${BOLD}Health:${NC}    http://127.0.0.1:${PORT_USED}/healthz"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    systemctl status github-agent"
echo "    journalctl -u github-agent -f"
echo "    tail -f $LOG_DIR/agent.log"
echo ""
echo -e "  ${BOLD}Manage / upgrade:${NC}"
echo "    curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash"
echo ""
