#!/usr/bin/env bash
# =============================================================================
# deploy-ai-sandbox.sh — Comprehensive AI Sandbox Factory
# =============================================================================
# Creates a fully-equipped Docker container as an "AI Sandbox" with:
#   - Multi-platform host detection (macOS, Arch, Debian/Ubuntu)
#   - Docker + Docker Compose installation & validation
#   - Configurable dev environment (.env driven)
#   - SSH key management
#   - Python (uv), Node.js, Claude Code, optional Go/.NET/TS/Rust
#   - RAG/RLM toolset (chromadb + sentence-transformers vector search)
#   - Multi-AI routing (Claude, Gemini, local models)
#   - YAML-driven DAG task runner with token budgeting & Telegram alerts
#   - Transcript rendering dashboard (nginx)
#   - Claude skills & Claudeception continuous-learning (optional)
#   - CLAUDE.md workspace rules for AI session optimization
# =============================================================================

set -euo pipefail

# ==========================================
# COLORS & HELPERS
# ==========================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
header() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

confirm() {
    local prompt="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}$prompt (y/n): ${NC}")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ==========================================
# 1. PLATFORM DETECTION & SYSTEM PRE-FLIGHT
# ==========================================
header "1. Platform Detection & System Pre-flight"

OS_TYPE="$(uname -s)"
ARCH="$(uname -m)"
DISTRO="unknown"

case "$OS_TYPE" in
    Darwin)
        DISTRO="macos"
        info "macOS detected ($ARCH). Using Homebrew."
        if ! command -v brew &>/dev/null; then
            info "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        brew install --quiet jq yq gh tmux python@3.11 2>/dev/null || true
        # Docker Desktop must be installed separately on macOS
        if ! command -v docker &>/dev/null; then
            warn "Docker not found. Please install Docker Desktop for macOS."
            warn "  https://docs.docker.com/desktop/install/mac-install/"
            exit 1
        fi
        # Ensure Docker daemon is running
        if ! docker info &>/dev/null 2>&1; then
            info "Starting Docker Desktop..."
            open -a Docker
            echo -n "Waiting for Docker daemon"
            for i in $(seq 1 30); do
                docker info &>/dev/null 2>&1 && break
                echo -n "."
                sleep 2
            done
            echo ""
            docker info &>/dev/null 2>&1 || { error "Docker did not start."; exit 1; }
        fi
        ;;
    Linux)
        if [ -f /etc/arch-release ]; then
            DISTRO="arch"
            info "Arch Linux detected. Using Pacman."
            sudo pacman -Sy --needed --noconfirm \
                git curl jq yq docker docker-compose github-cli \
                python python-pip tmux openssh ripgrep 2>/dev/null || true
            sudo systemctl enable --now docker
        elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
            DISTRO="debian"
            info "Debian/Ubuntu detected. Using APT."
            # Install Docker if missing (official method)
            if ! command -v docker &>/dev/null; then
                info "Installing Docker Engine..."
                sudo apt-get update
                sudo apt-get install -y ca-certificates curl gnupg
                sudo install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
                    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                sudo chmod a+r /etc/apt/keyrings/docker.gpg
                echo \
                  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                  https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
                  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
                  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
                sudo apt-get update
                sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
            fi
            # Install remaining host dependencies
            sudo apt-get install -y git curl jq tmux openssh-client ripgrep 2>/dev/null || true
            # yq may not be in default repos — install via binary if missing
            if ! command -v yq &>/dev/null; then
                info "Installing yq..."
                sudo wget -qO /usr/local/bin/yq \
                    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)"
                sudo chmod +x /usr/local/bin/yq
            fi
        else
            DISTRO="linux-other"
            warn "Unsupported Linux distro. Install Docker, jq, yq, tmux, git manually."
        fi
        # Ensure user is in docker group
        if ! groups | grep -q docker 2>/dev/null; then
            sudo usermod -aG docker "$USER" 2>/dev/null || true
            warn "Added $USER to docker group. You may need to log out/in for this to take effect."
        fi
        ;;
    *)
        error "Unsupported OS: $OS_TYPE"
        exit 1
        ;;
esac

# ==========================================
# 2. HOST TOOL INSTALLATION (uv, Claude Code)
# ==========================================
header "2. Host Tool Installation"

# --- Install uv (Python tool manager) ---
if ! command -v uv &>/dev/null; then
    info "Installing uv (Python package/tool manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# --- Install Claude Code (native binary installer — no npm required) ---
if ! command -v claude &>/dev/null; then
    info "Installing Claude Code CLI (native installer)..."
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
fi

# --- Docker API version compatibility ---
# If the Docker CLI is newer than the daemon, ALL docker commands fail with
# "client version X is too new". The CLI itself can't query the server version
# when this happens, so we bypass it entirely by querying the Docker socket
# directly with curl, then pin DOCKER_API_VERSION to what the daemon supports.
if ! docker version &>/dev/null 2>&1; then
    DOCKER_SOCK="/var/run/docker.sock"
    DAEMON_API=""
    if [[ -S "$DOCKER_SOCK" ]]; then
        # Query the daemon directly via Unix socket — bypasses CLI version check
        DAEMON_API=$(curl -s --unix-socket "$DOCKER_SOCK" http://localhost/version 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('ApiVersion',''))" 2>/dev/null || true)
    fi
    if [[ -z "$DAEMON_API" ]]; then
        # Last resort: parse the max version from the error message itself
        DAEMON_API=$(docker version 2>&1 | grep -oP 'Maximum supported API version is \K[0-9.]+' || true)
    fi
    if [[ -n "$DAEMON_API" ]]; then
        export DOCKER_API_VERSION="$DAEMON_API"
        info "Docker API mismatch detected. Pinning DOCKER_API_VERSION=$DAEMON_API"
    else
        error "Docker daemon not responding and could not determine API version."
        error "Try: export DOCKER_API_VERSION=1.41  then re-run this script."
        exit 1
    fi
fi

# --- Detect docker compose command ---
if docker compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif docker-compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    error "Neither 'docker compose' nor 'docker-compose' found."
    exit 1
fi
info "Using: $DOCKER_COMPOSE"

# ==========================================
# 3. PROJECT CONFIGURATION
# ==========================================
header "3. Project Configuration"

PROJECT_NAME="${1:-ai-sandbox}"
# Find the first available port starting from 7337
BASE_PORT=7337
while (echo > /dev/tcp/127.0.0.1/$BASE_PORT) >/dev/null 2>&1; do
    BASE_PORT=$((BASE_PORT + 1))
done
export DASHBOARD_PORT=$BASE_PORT
BASE_DIR="$HOME/ai-sandbox-projects/$PROJECT_NAME"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"

info "Project: $PROJECT_NAME"
info "Location: $BASE_DIR"

# --- Directory Structure ---
mkdir -p "$BASE_DIR"/{config,workspace,logs,scripts/rlm,ssh,rag_db,transcripts/archive,private}
cd "$BASE_DIR"

# --- SSH Key ---
if [[ -f "$SSH_KEY_PATH" ]]; then
    info "Copying SSH key from $SSH_KEY_PATH"
    cp "$SSH_KEY_PATH" "$BASE_DIR/ssh/id_rsa"
    [[ -f "${SSH_KEY_PATH}.pub" ]] && cp "${SSH_KEY_PATH}.pub" "$BASE_DIR/ssh/id_rsa.pub"
else
    if confirm "No SSH key found at $SSH_KEY_PATH. Generate a new one?"; then
        ssh-keygen -t ed25519 -f "$BASE_DIR/ssh/id_rsa" -N "" -C "ai-sandbox-$PROJECT_NAME"
        info "New key generated. Add the public key to your Git provider:"
        cat "$BASE_DIR/ssh/id_rsa.pub"
    else
        warn "Skipping SSH key setup. Git over SSH won't work inside the container."
    fi
fi
[[ -f "$BASE_DIR/ssh/id_rsa" ]] && chmod 600 "$BASE_DIR/ssh/id_rsa"

# --- .env File ---
if [[ ! -f .env ]]; then
    info "Creating .env configuration..."
    echo ""

    read -rp "Anthropic API Key (leave blank to skip): " ANTHROPIC_KEY
    read -rp "Google/Gemini API Key (leave blank to skip): " GOOGLE_KEY

    echo ""
    echo -e "${CYAN}${BOLD}--- Telegram Notifications (Optional) ---${NC}"
    echo -e "Telegram notifications are sent during ${BOLD}task automation${NC} (gsd-run command)."
    echo -e "Use cases:"
    echo -e "  - Get notified when long-running task DAGs complete"
    echo -e "  - Track token usage and budget alerts"
    echo -e "  - Monitor multi-step workflows remotely"
    echo -e ""
    echo -e "Setup: Create a bot via @BotFather on Telegram, then get your chat ID."
    echo -e "Note: Also used by Ralph Orchestrator if you install it later."
    echo ""
    read -rp "Telegram Bot Token (leave blank to skip): " TG_TOKEN
    read -rp "Telegram Chat ID (leave blank to skip): " TG_CHAT

    echo ""
    read -rp "Daily token budget [50000]: " MAX_TOKENS
    MAX_TOKENS="${MAX_TOKENS:-50000}"

    echo ""
    info "Optional language runtimes (true/false):"
    read -rp "  Install Go? [false]: " INSTALL_GO
    read -rp "  Install .NET? [false]: " INSTALL_DOTNET
    read -rp "  Install TypeScript/Node tools? [true]: " INSTALL_JS_TS
    read -rp "  Install Rust? [false]: " INSTALL_RUST

    echo ""
    echo -e "${RED}${BOLD}--- Local AI Warning ---${NC}"
    echo -e "Installing local AI tools (sentence-transformers, PyTorch, Ollama)"
    echo -e "adds ${RED}~4-6 GB${NC} to the Docker image and significantly increases build time."
    echo -e "Without local AI, the sandbox still has full RAG/vector search using"
    echo -e "lightweight ONNX embeddings — no quality loss for code search."
    echo -e "Local AI is only needed if you want to run models ${BOLD}inside${NC} the container"
    echo -e "(e.g. Ollama, local LLMs, GPU-accelerated embeddings)."
    echo ""
    read -rp "  Install local AI tools (PyTorch, sentence-transformers, Ollama)? [false]: " INSTALL_LOCAL_AI

    cat > .env <<EOF
# === AI Sandbox Configuration ===
PROJECT_NAME=${PROJECT_NAME}

# --- API Keys ---
ANTHROPIC_API_KEY=${ANTHROPIC_KEY}
GOOGLE_API_KEY=${GOOGLE_KEY}

# --- Notifications ---
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
TELEGRAM_CHAT_ID=${TG_CHAT}

# --- Budget ---
MAX_TOKEN_LIMIT=${MAX_TOKENS}

# --- Optional Language Runtimes ---
INSTALL_GOLANG=${INSTALL_GO:-false}
INSTALL_DOTNET=${INSTALL_DOTNET:-false}
INSTALL_JS_TS=${INSTALL_JS_TS:-true}
INSTALL_RUST=${INSTALL_RUST:-false}

# --- Local AI (WARNING: adds ~4-6 GB to image) ---
ENABLE_LOCAL_AI=${INSTALL_LOCAL_AI:-false}

# --- Orchestration Tools ---
INSTALL_GSD=false
INSTALL_RALPH=false

# --- Features ---
ENABLE_DASHBOARD=true
ENABLE_RAG=true
EOF
    info ".env created."
else
    info ".env already exists, loading it."
fi

# Source .env for use in this script
set -a
source .env
set +a

# ==========================================
# 4. CLAUDE SKILLS & EXTENSIONS (Optional)
# ==========================================
header "4. Claude Skills & Extensions (Optional)"

# Create skills directory with proper permissions.
# If ~/.claude is owned by a different UID (e.g., container UID 1000 from a previous
# deployment), mkdir/git-clone will fail with "Permission denied". Fix ownership first.
if [[ -d "$HOME/.claude" ]] && [[ ! -w "$HOME/.claude" ]]; then
    warn "$HOME/.claude exists but is not writable (likely owned by container UID 1000 from a previous run)."
    info "Fixing ownership with sudo..."
    sudo chown -R "$(id -u):$(id -g)" "$HOME/.claude" || {
        error "Could not fix $HOME/.claude permissions."
        error "Run manually: sudo chown -R \$(id -u):\$(id -g) $HOME/.claude"
    }
fi
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/hooks"
chmod 755 "$HOME/.claude" "$HOME/.claude/skills" "$HOME/.claude/hooks" 2>/dev/null || true

if confirm "Install curated Claude skills (awesome-claude-skills)?"; then
    if [ ! -d "$HOME/.claude/skills/awesome-claude-skills" ]; then
        if git clone https://github.com/ComposioHQ/awesome-claude-skills.git \
            "$HOME/.claude/skills/awesome-claude-skills"; then
            info "Installed awesome-claude-skills."
        else
            error "Failed to clone awesome-claude-skills. Skipping (non-fatal)."
        fi
    else
        info "awesome-claude-skills already present."
    fi
fi

if confirm "Install experimental skills sandbox (everything-claude-code)?"; then
    if [ ! -d "$HOME/.claude/skills/everything-sandbox" ]; then
        if git clone https://github.com/affaan-m/everything-claude-code.git \
            "$HOME/.claude/skills/everything-sandbox"; then
            info "Installed everything-claude-code (sandbox)."
        else
            error "Failed to clone everything-claude-code. Skipping (non-fatal)."
        fi
    else
        info "everything-claude-code already present."
    fi
fi

if confirm "Install marketing-focused Claude skills (marketingskills)?"; then
    if [ ! -d "$HOME/.claude/skills/marketingskills" ]; then
        if git clone https://github.com/coreyhaines31/marketingskills.git \
            "$HOME/.claude/skills/marketingskills"; then
            info "Installed marketingskills."
        else
            error "Failed to clone marketingskills. Skipping (non-fatal)."
        fi
    else
        info "marketingskills already present."
    fi
fi

echo ""
echo -e "${YELLOW}${BOLD}--- Claudeception Warning ---${NC}"
echo -e "Claudeception enables continuous learning and self-improvement loops."
echo -e "${RED}WARNING: Using this might cause context drift${NC} - Claude may accumulate"
echo -e "patterns from previous sessions that affect current behavior."
echo -e "Recommended for: experimental workflows, research, meta-learning"
echo -e "Not recommended for: production, deterministic tasks, compliance work"
echo ""
if confirm "Install Claudeception (continuous learning, may cause context drift)?"; then
    if [ ! -d "$HOME/.claude/skills/claudeception" ]; then
        if git clone https://github.com/blader/Claudeception.git \
            "$HOME/.claude/skills/claudeception"; then
            info "Installed Claudeception (use with caution)."
        else
            error "Failed to clone Claudeception. Skipping (non-fatal)."
        fi
    else
        info "Claudeception already present."
    fi
fi

if confirm "Install agent toolkits (browser-use, open-interpreter) via uv?"; then
    uv tool install browser-use 2>/dev/null || warn "browser-use install failed (non-fatal)."
    uv tool install open-interpreter 2>/dev/null || warn "open-interpreter install failed (non-fatal)."
    info "Agent toolkits installed."
fi

# ==========================================
# 4a. ORCHESTRATION TOOLS (Optional)
# ==========================================
header "4a. Orchestration Tools (Optional)"

echo ""
echo -e "${CYAN}Orchestration tools help manage complex multi-step AI workflows:${NC}"
echo -e "  - ${BOLD}GSD (Get Stuff Done)${NC}: Task automation and workflow orchestration"
echo -e "  - ${BOLD}Ralph Orchestrator${NC}: Advanced multi-agent coordination framework"
echo ""

INSTALL_GSD=false
if confirm "Install GSD (Get Stuff Done) orchestration tool?"; then
    INSTALL_GSD=true
    if command -v npm &>/dev/null; then
        info "Installing GSD via npm..."
        npm install -g get-stuff-done-ai 2>/dev/null || warn "GSD npm install failed. Will try alternative method."
    fi
    # Alternative: clone from GitHub if available
    if ! command -v gsd &>/dev/null && [ ! -f ~/.local/bin/gsd ]; then
        warn "GSD not found via npm. Checking for GitHub repository..."
        # Note: If GSD has a GitHub repo, we can clone it here
        # For now, we'll create a placeholder that uses the built-in scripts
        mkdir -p ~/.local/bin
        cat > ~/.local/bin/gsd <<'GSDEOF'
#!/bin/bash
# GSD wrapper for AI Sandbox built-in task runner
# This script bridges 'gsd' commands to the sandbox's internal tools
case "$1" in
    run)
        shift
        exec gsd-run "$@"
        ;;
    route)
        shift
        exec gsd-route "$@"
        ;;
    help|--help|-h)
        exec gsd-help
        ;;
    *)
        echo "GSD - Get Stuff Done AI Orchestrator"
        echo "Usage: gsd <command> [options]"
        echo ""
        echo "Commands:"
        echo "  run <task.yaml>        Execute a YAML task DAG"
        echo "  route <type> <prompt>  Route prompt to best AI"
        echo "  help                   Show help"
        exit 1
        ;;
esac
GSDEOF
        chmod +x ~/.local/bin/gsd
        info "GSD wrapper installed to ~/.local/bin/gsd"
    fi
fi

INSTALL_RALPH=false
if confirm "Install Ralph Orchestrator (advanced multi-agent framework)?"; then
    INSTALL_RALPH=true
    if [ ! -d ~/.local/share/ralph-orchestrator ]; then
        info "Installing Ralph Orchestrator..."
        git clone https://github.com/mikeyobrien/ralph-orchestrator.git \
            ~/.local/share/ralph-orchestrator
        cd ~/.local/share/ralph-orchestrator
        if [ -f requirements.txt ]; then
            uv pip install -r requirements.txt 2>/dev/null || \
                pip3 install -r requirements.txt 2>/dev/null || \
                warn "Ralph Orchestrator dependencies install failed. Install manually if needed."
        fi
        # Create symlink to bin if setup script exists
        if [ -f setup.py ]; then
            uv pip install -e . 2>/dev/null || \
                pip3 install -e . 2>/dev/null || \
                warn "Ralph Orchestrator setup failed. See ~/.local/share/ralph-orchestrator for manual setup."
        fi
        cd - > /dev/null
        info "Ralph Orchestrator installed to ~/.local/share/ralph-orchestrator"
    else
        info "Ralph Orchestrator already present."
    fi
fi

# Update .env with orchestration tool flags
if [[ -f .env ]]; then
    # Update existing .env file with orchestration flags
    if grep -q "^INSTALL_GSD=" .env 2>/dev/null; then
        sed -i.bak "s/^INSTALL_GSD=.*/INSTALL_GSD=${INSTALL_GSD}/" .env
    else
        echo "INSTALL_GSD=${INSTALL_GSD}" >> .env
    fi
    if grep -q "^INSTALL_RALPH=" .env 2>/dev/null; then
        sed -i.bak "s/^INSTALL_RALPH=.*/INSTALL_RALPH=${INSTALL_RALPH}/" .env
    else
        echo "INSTALL_RALPH=${INSTALL_RALPH}" >> .env
    fi
    rm -f .env.bak
    # Reload .env
    set -a
    source .env
    set +a
fi

# ==========================================
# 5. GENERATE DOCKERFILE
# ==========================================
header "5. Generating Dockerfile"

cat > Dockerfile <<'DOCKERFILE'
FROM debian:bookworm-slim

# --- Build Arguments (toggled via .env) ---
ARG INSTALL_GOLANG=false
ARG INSTALL_DOTNET=false
ARG INSTALL_JS_TS=true
ARG INSTALL_RUST=false
ARG ENABLE_LOCAL_AI=false
ARG INSTALL_GSD=false
ARG INSTALL_RALPH=false

ENV DEBIAN_FRONTEND=noninteractive
ENV UV_LINK_MODE=copy

# --- Base System (installed as root) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git jq tmux unzip build-essential \
    ca-certificates gnupg lsb-release \
    python3-full python3-pip python3-venv \
    openssh-client iputils-ping dnsutils \
    ripgrep fd-find fzf bat \
    sudo less vim-tiny gosu \
    && rm -rf /var/lib/apt/lists/*

# --- Create non-root user: ai-worker ---
RUN groupadd -g 1000 ai-worker \
    && useradd -m -u 1000 -g ai-worker -s /bin/bash ai-worker \
    && echo "ai-worker ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ai-worker \
    && chmod 0440 /etc/sudoers.d/ai-worker \
    && mkdir -p /home/ai-worker/.local/bin /home/ai-worker/.ssh \
    && mkdir -p /home/ai-worker/.claude/session-env /home/ai-worker/.claude/shell-snapshots \
    && chown -R ai-worker:ai-worker /home/ai-worker \
    && chmod 755 /home/ai-worker/.claude /home/ai-worker/.claude/session-env /home/ai-worker/.claude/shell-snapshots

# --- Node.js 20.x LTS (system-wide, for tooling) ---
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- yq (YAML processor, system-wide) ---
RUN ARCH=$(dpkg --print-architecture) \
    && wget -qO /usr/local/bin/yq \
       "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
    && chmod +x /usr/local/bin/yq

# --- RAG / RLM Python packages (always installed — core dependency for RLM tools) ---
RUN pip3 install --break-system-packages \
    chromadb \
    onnxruntime \
    tokenizers \
    llm \
    rich

# --- Local AI: sentence-transformers + PyTorch (heavy — adds ~4-6 GB) ---
RUN if [ "$ENABLE_LOCAL_AI" = "true" ]; then \
    pip3 install --break-system-packages \
        sentence-transformers \
        torch --index-url https://download.pytorch.org/whl/cpu; \
    fi

# --- Local AI: Ollama (local LLM runner) ---
RUN if [ "$ENABLE_LOCAL_AI" = "true" ]; then \
    curl -fsSL https://ollama.com/install.sh | sh || true; \
    fi

# --- Optional: Go ---
RUN if [ "$INSTALL_GOLANG" = "true" ]; then \
    curl -OL https://go.dev/dl/go1.22.4.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf go1.22.4.linux-amd64.tar.gz \
    && rm go1.22.4.linux-amd64.tar.gz; \
    fi

# --- Optional: .NET SDK (requires Microsoft repo on Debian) ---
RUN if [ "$INSTALL_DOTNET" = "true" ]; then \
    wget -qO /tmp/packages-microsoft-prod.deb \
        "https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb" \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y dotnet-sdk-8.0 \
    && rm -rf /var/lib/apt/lists/*; \
    fi

# --- Optional: TypeScript / Node tools ---
RUN if [ "$INSTALL_JS_TS" = "true" ]; then \
    npm install -g typescript ts-node eslint prettier; \
    fi

# --- Optional: Rust (installed for ai-worker) ---
RUN if [ "$INSTALL_RUST" = "true" ]; then \
    gosu ai-worker bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'; \
    fi

# --- Install uv + Claude Code as ai-worker (not root) ---
USER ai-worker
WORKDIR /home/ai-worker

ENV PATH="/home/ai-worker/.local/bin:/home/ai-worker/.cargo/bin:/usr/local/go/bin:$PATH"

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN curl -fsSL https://claude.ai/install.sh | bash

# --- Transcript renderer (simonw) ---
RUN git clone --depth=1 https://github.com/simonw/claude-code-transcripts \
    /home/ai-worker/tools/transcripts 2>/dev/null || true

# --- Optional: GSD (Get Stuff Done) orchestrator ---
RUN if [ "$INSTALL_GSD" = "true" ]; then \
    mkdir -p /home/ai-worker/.local/bin && \
    printf '%s\n' \
        '#!/bin/bash' \
        '# GSD wrapper for AI Sandbox built-in task runner' \
        'case "$1" in' \
        '    run)' \
        '        shift' \
        '        exec gsd-run "$@"' \
        '        ;;' \
        '    route)' \
        '        shift' \
        '        exec gsd-route "$@"' \
        '        ;;' \
        '    help|--help|-h)' \
        '        exec gsd-help' \
        '        ;;' \
        '    *)' \
        '        echo "GSD - Get Stuff Done AI Orchestrator"' \
        '        echo "Usage: gsd <command> [options]"' \
        '        echo ""' \
        '        echo "Commands:"' \
        '        echo "  run <task.yaml>        Execute a YAML task DAG"' \
        '        echo "  route <type> <prompt>  Route prompt to best AI"' \
        '        echo "  help                   Show help"' \
        '        exit 1' \
        '        ;;' \
        'esac' \
        > /home/ai-worker/.local/bin/gsd && \
    chmod +x /home/ai-worker/.local/bin/gsd; \
    fi

# --- Optional: Ralph Orchestrator (multi-agent framework) ---
RUN if [ "$INSTALL_RALPH" = "true" ]; then \
    git clone --depth=1 https://github.com/mikeyobrien/ralph-orchestrator.git \
        /home/ai-worker/tools/ralph-orchestrator 2>/dev/null || true && \
    if [ -f /home/ai-worker/tools/ralph-orchestrator/requirements.txt ]; then \
        /home/ai-worker/.local/bin/uv pip install -r /home/ai-worker/tools/ralph-orchestrator/requirements.txt 2>/dev/null || true; \
    fi; \
    fi

# Switch back to root for entrypoint (it drops privileges after setup)
USER root
WORKDIR /workspace
CMD ["/bin/bash"]
DOCKERFILE

info "Dockerfile written."

# ==========================================
# 6. GENERATE DOCKER COMPOSE
# ==========================================
header "6. Generating docker-compose.yml"

cat > docker-compose.yml <<EOF
services:
  ai-sandbox:
    build:
      context: .
      args:
        INSTALL_GOLANG: \${INSTALL_GOLANG:-false}
        INSTALL_DOTNET: \${INSTALL_DOTNET:-false}
        INSTALL_JS_TS: \${INSTALL_JS_TS:-true}
        INSTALL_RUST: \${INSTALL_RUST:-false}
        ENABLE_LOCAL_AI: \${ENABLE_LOCAL_AI:-false}
        INSTALL_GSD: \${INSTALL_GSD:-false}
        INSTALL_RALPH: \${INSTALL_RALPH:-false}
    image: ai-sandbox-\${PROJECT_NAME:-sandbox}
    container_name: ai-sandbox-\${PROJECT_NAME:-sandbox}
    volumes:
      - ./workspace:/workspace
      - ./config:/home/ai-worker/.config
      - ./ssh:/home/ai-worker/.ssh
      - ./scripts:/scripts
      - ./rag_db:/rag_db
      - ./logs:/workspace/logs
      - ./transcripts:/transcripts
      - ./private:/private:ro
      - \${HOME}/.claude:/home/ai-worker/.claude:rw
    env_file: .env
    environment:
      - TERM=xterm-256color
      - HOME=/home/ai-worker
    tty: true
    stdin_open: true
    entrypoint: ["/bin/bash", "/scripts/entrypoint.sh"]
    restart: unless-stopped

  dashboard:
    image: nginx:alpine
    container_name: ai-sandbox-dashboard-\${PROJECT_NAME:-sandbox}
    ports:
      - "127.0.0.1:$DASHBOARD_PORT:80"
    volumes:
      - ./transcripts:/usr/share/nginx/html:ro
    restart: unless-stopped
    profiles:
      - dashboard
EOF

info "docker-compose.yml written."

# ==========================================
# 7. GENERATE RLM / RAG PYTHON TOOLS
# ==========================================
header "7. Generating RLM (RAG) Tools"

# --- 7a. Indexer: Scans workspace, builds vector DB ---
cat > scripts/rlm/indexer.py <<'PYEOF'
#!/usr/bin/env python3
"""RLM Indexer — Scans the workspace and builds a ChromaDB vector index.

Supports two embedding modes:
  - Standard: ChromaDB's built-in ONNX embeddings (lightweight, no PyTorch)
  - Local AI: sentence-transformers with PyTorch (if installed)
The mode is auto-detected based on available packages.
"""
import os
import sys
import chromadb

DB_PATH = os.environ.get("RLM_DB_PATH", "/rag_db/chroma")
WORKSPACE = os.environ.get("RLM_WORKSPACE", "/workspace")
EXTENSIONS = {".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs", ".cs",
              ".md", ".txt", ".sh", ".yaml", ".yml", ".json", ".toml"}
SKIP_DIRS = {"node_modules", ".git", "__pycache__", ".venv", "venv",
             ".next", "dist", "build", "target", ".mypy_cache"}
CHUNK_SIZE = 1000
CHUNK_OVERLAP = 200
MIN_CHUNK_LEN = 50

def get_embedding_function():
    """Return the best available embedding function."""
    try:
        from sentence_transformers import SentenceTransformer
        print("RLM Indexer: Using sentence-transformers (local AI mode).")
        from chromadb.utils.embedding_functions import SentenceTransformerEmbeddingFunction
        return SentenceTransformerEmbeddingFunction(model_name="all-MiniLM-L6-v2")
    except ImportError:
        print("RLM Indexer: Using ChromaDB default ONNX embeddings (standard mode).")
        from chromadb.utils.embedding_functions import DefaultEmbeddingFunction
        return DefaultEmbeddingFunction()

def chunk_text(text, size=CHUNK_SIZE, overlap=CHUNK_OVERLAP):
    """Split text into overlapping chunks."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + size
        chunk = text[start:end]
        if len(chunk.strip()) >= MIN_CHUNK_LEN:
            chunks.append(chunk)
        start += size - overlap
    return chunks

def main():
    print("RLM Indexer: Initializing...")
    embed_fn = get_embedding_function()
    client = chromadb.PersistentClient(path=DB_PATH)

    # Reset collection for a clean re-index
    try:
        client.delete_collection(name="codebase")
    except Exception:
        pass
    collection = client.create_collection(
        name="codebase",
        embedding_function=embed_fn
    )

    documents = []
    metadatas = []
    ids = []
    file_count = 0

    print(f"RLM Indexer: Scanning {WORKSPACE}...")
    for root, dirs, files in os.walk(WORKSPACE):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fname in files:
            ext = os.path.splitext(fname)[1]
            if ext not in EXTENSIONS:
                continue
            fpath = os.path.join(root, fname)
            try:
                with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read()
                if not content.strip():
                    continue
                file_count += 1
                rel_path = os.path.relpath(fpath, WORKSPACE)
                chunks = chunk_text(content)
                for idx, chunk in enumerate(chunks):
                    documents.append(chunk)
                    metadatas.append({"source": rel_path, "chunk_id": idx,
                                      "abs_path": fpath})
                    ids.append(f"{rel_path}::{idx}")
            except Exception:
                pass

    if documents:
        print(f"RLM Indexer: Indexing {len(documents)} chunks from {file_count} files...")
        # Batch upsert (ChromaDB has a batch limit)
        batch = 500
        for i in range(0, len(documents), batch):
            collection.upsert(
                documents=documents[i:i+batch],
                metadatas=metadatas[i:i+batch],
                ids=ids[i:i+batch]
            )
        print(f"RLM Indexer: Done. {len(documents)} chunks indexed.")
    else:
        print("RLM Indexer: No indexable files found in workspace.")

if __name__ == "__main__":
    main()
PYEOF

# --- 7b. Semantic Search ---
cat > scripts/rlm/search.py <<'PYEOF'
#!/usr/bin/env python3
"""RLM Search — Semantic code search over the indexed workspace.

Auto-detects embedding mode (sentence-transformers or ONNX default)
to match whatever was used during indexing.
"""
import os
import sys
import chromadb

DB_PATH = os.environ.get("RLM_DB_PATH", "/rag_db/chroma")

def get_embedding_function():
    """Return the best available embedding function (must match indexer)."""
    try:
        from sentence_transformers import SentenceTransformer
        from chromadb.utils.embedding_functions import SentenceTransformerEmbeddingFunction
        return SentenceTransformerEmbeddingFunction(model_name="all-MiniLM-L6-v2")
    except ImportError:
        from chromadb.utils.embedding_functions import DefaultEmbeddingFunction
        return DefaultEmbeddingFunction()

def main():
    if len(sys.argv) < 2:
        print("Usage: rlm-search '<query>' [num_results]")
        print("  Searches the codebase by meaning, not just keywords.")
        sys.exit(1)

    query = sys.argv[1]
    n_results = int(sys.argv[2]) if len(sys.argv) > 2 else 5

    embed_fn = get_embedding_function()
    client = chromadb.PersistentClient(path=DB_PATH)

    try:
        collection = client.get_collection(
            name="codebase",
            embedding_function=embed_fn
        )
    except Exception:
        print("Error: No index found. Run 'rlm-index' first.")
        sys.exit(1)

    results = collection.query(query_texts=[query], n_results=n_results)

    print(f"\n--- RLM Search Results for: '{query}' ---\n")
    if not results['documents'][0]:
        print("No results found.")
        return

    for i, doc in enumerate(results['documents'][0]):
        meta = results['metadatas'][0][i]
        distance = results['distances'][0][i] if results.get('distances') else "N/A"
        print(f"[{i+1}] {meta['source']} (chunk {meta['chunk_id']}, distance: {distance:.4f})")
        print("-" * 60)
        # Show first 500 chars of the chunk
        preview = doc.strip()[:500]
        print(preview)
        if len(doc.strip()) > 500:
            print("  ...")
        print()

if __name__ == "__main__":
    main()
PYEOF

# --- 7c. AST Mapper (Python file structure) ---
cat > scripts/rlm/ast_map.py <<'PYEOF'
#!/usr/bin/env python3
"""RLM Map — Displays the structural outline (classes, functions) of a Python file."""
import ast
import sys
import os

def map_file(filepath):
    """Parse and display the AST structure of a Python file."""
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}")
        sys.exit(1)

    with open(filepath, "r", encoding="utf-8") as f:
        source = f.read()

    try:
        tree = ast.parse(source)
    except SyntaxError as e:
        print(f"Error: Could not parse {filepath}: {e}")
        sys.exit(1)

    print(f"\nStructure Map: {filepath}")
    print("=" * 60)

    for node in ast.iter_child_nodes(tree):
        if isinstance(node, ast.ClassDef):
            bases = ", ".join(
                getattr(b, 'id', getattr(b, 'attr', '?'))
                for b in node.bases
            )
            base_str = f"({bases})" if bases else ""
            print(f"\n  class {node.name}{base_str}:  [line {node.lineno}]")
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    args = ", ".join(a.arg for a in item.args.args)
                    deco = ""
                    if item.decorator_list:
                        deco_names = []
                        for d in item.decorator_list:
                            deco_names.append(getattr(d, 'id', getattr(d, 'attr', '?')))
                        deco = f"  @{', @'.join(deco_names)}"
                    print(f"    def {item.name}({args})  [line {item.lineno}]{deco}")

        elif isinstance(node, ast.FunctionDef):
            args = ", ".join(a.arg for a in node.args.args)
            print(f"\n  def {node.name}({args})  [line {node.lineno}]")

        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            pass  # Skip imports for brevity

    print()

def main():
    if len(sys.argv) < 2:
        print("Usage: rlm-map <file.py> [file2.py ...]")
        print("  Displays class/function structure of Python files.")
        sys.exit(1)

    for filepath in sys.argv[1:]:
        map_file(filepath)

if __name__ == "__main__":
    main()
PYEOF

info "RLM tools written to scripts/rlm/"

# ==========================================
# 8. GENERATE RUNTIME SCRIPTS
# ==========================================
header "8. Generating Runtime Scripts"

# --- 8a. Entrypoint ---
cat > scripts/entrypoint.sh <<'SCRIPTEOF'
#!/bin/bash
set -e

AI_USER="ai-worker"
AI_HOME="/home/$AI_USER"

echo "--- AI Sandbox: Initializing (as root, will drop to $AI_USER) ---"

# =============================================
# Phase 1: Permission fixes (runs as root)
# =============================================

# Fix ownership of all mounted volumes
chown -R $AI_USER:$AI_USER "$AI_HOME/.ssh" 2>/dev/null || true
chown -R $AI_USER:$AI_USER "$AI_HOME/.config" 2>/dev/null || true
chown -R $AI_USER:$AI_USER /workspace 2>/dev/null || true
chown -R $AI_USER:$AI_USER /rag_db 2>/dev/null || true
chown -R $AI_USER:$AI_USER /transcripts 2>/dev/null || true
chown -R $AI_USER:$AI_USER /workspace/logs 2>/dev/null || true

# --- Claude Code directory setup (CRITICAL FOR PERMISSIONS) ---
# Claude Code needs to create session-env and shell-snapshots subdirectories.
# If the host's .claude directory is mounted, it may have incorrect ownership.
# We must:
#   1. Create the directory structure if it doesn't exist
#   2. Fix ownership to ai-worker
#   3. Ensure proper permissions (755 for dirs, 644 for files)
echo "Setting up Claude Code directories..."
mkdir -p "$AI_HOME/.claude/session-env" "$AI_HOME/.claude/shell-snapshots" 2>/dev/null || true
chown -R $AI_USER:$AI_USER "$AI_HOME/.claude" 2>/dev/null || true
chmod -R u+rwX,go+rX,go-w "$AI_HOME/.claude" 2>/dev/null || true

# Verify the permissions were actually set (don't fail silently)
if [ ! -w "$AI_HOME/.claude/session-env" ]; then
    echo "WARNING: $AI_HOME/.claude/session-env is not writable by $AI_USER"
    echo "Attempting forceful permission fix..."
    chmod 755 "$AI_HOME/.claude" "$AI_HOME/.claude/session-env" "$AI_HOME/.claude/shell-snapshots" 2>/dev/null || true
    chown -R $AI_USER:$AI_USER "$AI_HOME/.claude" 2>/dev/null || true
fi

# Scripts stay root-owned but world-executable
chmod +x /scripts/*.sh 2>/dev/null || true
chmod +x /scripts/rlm/*.py 2>/dev/null || true

# --- SSH setup (fix permissions for ai-worker) ---
if [ -f "$AI_HOME/.ssh/id_rsa" ]; then
    chmod 700 "$AI_HOME/.ssh"
    chmod 600 "$AI_HOME/.ssh/id_rsa"
    chmod 644 "$AI_HOME/.ssh/id_rsa.pub" 2>/dev/null || true
    # Pre-populate known_hosts so git clone doesn't prompt
    gosu $AI_USER ssh-keyscan github.com gitlab.com bitbucket.org \
        >> "$AI_HOME/.ssh/known_hosts" 2>/dev/null || true
    chmod 644 "$AI_HOME/.ssh/known_hosts" 2>/dev/null || true
fi

# =============================================
# Phase 2: User-space setup (as ai-worker)
# =============================================

# --- Python venv in workspace ---
cd /workspace
if [ ! -d ".venv" ]; then
    echo "Initializing Python virtual environment..."
    gosu $AI_USER bash -c 'export PATH="/home/ai-worker/.local/bin:$PATH" && uv venv --quiet --system-site-packages' 2>/dev/null || true
fi

# --- Logs directory ---
mkdir -p /workspace/logs
chown $AI_USER:$AI_USER /workspace/logs

# --- Shell config for ai-worker ---
cat > "$AI_HOME/.bashrc" <<'BASHRC'
# AI Sandbox — ai-worker shell config
export PATH="/home/ai-worker/.local/bin:/home/ai-worker/.cargo/bin:/scripts/rlm:/scripts:/usr/local/go/bin:$PATH"
export HOME="/home/ai-worker"

alias rlm-index='python3 /scripts/rlm/indexer.py'
alias rlm-search='python3 /scripts/rlm/search.py'
alias rlm-map='python3 /scripts/rlm/ast_map.py'
alias gsd-run='/scripts/task_runner.sh'
alias gsd-route='/scripts/ai_router.sh'
alias gsd-transcripts='/scripts/render_transcripts.sh'
alias gsd-telegram-test='/scripts/test_telegram.sh'
alias gsd-help='/scripts/help.sh'

# SSH agent (if key present)
if [ -f "$HOME/.ssh/id_rsa" ]; then
    eval "$(ssh-agent -s)" > /dev/null 2>&1
    ssh-add "$HOME/.ssh/id_rsa" 2>/dev/null || true
fi

# Activate workspace venv if present
if [ -d "/workspace/.venv" ]; then
    source /workspace/.venv/bin/activate
fi

cd /workspace
BASHRC
chown $AI_USER:$AI_USER "$AI_HOME/.bashrc"

# --- Startup banner ---
LOCAL_AI_STATUS="OFF (lightweight ONNX embeddings)"
if python3 -c "import sentence_transformers" 2>/dev/null; then
    LOCAL_AI_STATUS="ON (sentence-transformers + PyTorch)"
fi
OLLAMA_STATUS=""
if command -v ollama &>/dev/null; then
    OLLAMA_STATUS="    ollama             Local LLM runner (local AI mode)"
fi
GSD_STATUS=""
if command -v gsd &>/dev/null; then
    GSD_STATUS="    gsd                GSD orchestrator (installed)"
fi
RALPH_STATUS=""
if [ -d /home/ai-worker/tools/ralph-orchestrator ]; then
    RALPH_STATUS="    ralph              Ralph multi-agent framework (installed)"
fi

echo ""
echo "================================================"
echo "  AI Sandbox Ready (user: $AI_USER)"
echo "  Local AI: $LOCAL_AI_STATUS"
echo "================================================"
echo ""
echo "  Available commands:"
echo "    rlm-index          Scan workspace & build vector DB"
echo "    rlm-search <q>     Semantic code search"
echo "    rlm-map <file.py>  Show Python file structure"
echo "    gsd-run <task.yml> Execute a YAML task DAG"
echo "    gsd-route <type> <prompt>  Route to best AI"
echo "    gsd-transcripts    Render session transcripts"
echo "    gsd-telegram-test  Test Telegram notifications"
echo "    gsd-help           Show this help"
echo "    claude             Start Claude Code session"
if [ -n "$OLLAMA_STATUS" ]; then
    echo "$OLLAMA_STATUS"
fi
if [ -n "$GSD_STATUS" ]; then
    echo "$GSD_STATUS"
fi
if [ -n "$RALPH_STATUS" ]; then
    echo "$RALPH_STATUS"
fi
echo ""

# =============================================
# Phase 3: Signal readiness, drop privileges, and keep alive
# =============================================
touch /tmp/.entrypoint-done
exec gosu $AI_USER tail -f /dev/null
SCRIPTEOF

# --- 8b. Help ---
cat > scripts/help.sh <<'SCRIPTEOF'
#!/bin/bash
echo ""
echo "=== AI Sandbox Commands ==="
echo ""

# Detect local AI mode
if python3 -c "import sentence_transformers" 2>/dev/null; then
    echo "  Embedding mode: sentence-transformers (local AI)"
else
    echo "  Embedding mode: ONNX default (lightweight)"
fi
echo ""

echo "  RLM (RAG) Tools:"
echo "    rlm-index              Build/rebuild the vector search index"
echo "    rlm-search '<query>'   Semantic search over your codebase"
echo "    rlm-map <file.py>      Display Python file structure (AST)"
echo ""
echo "  Task Automation:"
echo "    gsd-run <task.yaml>    Execute a YAML-defined task DAG"
echo "    gsd-route <type> <p>   Route prompt to best AI (claude/gemini/local)"
echo ""

if command -v gsd &>/dev/null; then
    echo "  GSD Orchestrator (installed):"
    echo "    gsd run <task.yaml>    Execute task workflows"
    echo "    gsd route <type> <p>   Route to optimal AI"
    echo "    gsd help               Show GSD help"
    echo ""
fi

if [ -d /home/ai-worker/tools/ralph-orchestrator ]; then
    echo "  Ralph Orchestrator (installed):"
    echo "    Location: ~/tools/ralph-orchestrator"
    echo "    Advanced multi-agent coordination framework"
    echo ""
fi

echo "  Session Management:"
echo "    gsd-transcripts        Render Claude session transcripts to HTML"
echo "    claude                 Start interactive Claude Code session"
echo ""

echo "  Notifications:"
echo "    gsd-telegram-test      Test Telegram integration"
echo "    (Telegram auto-sends during gsd-run task execution)"
echo ""

if command -v ollama &>/dev/null; then
    echo "  Local AI (installed):"
    echo "    ollama run <model>     Run a local LLM (e.g. codellama, llama3)"
    echo "    ollama list            List downloaded models"
    echo ""
fi

echo "  Tips:"
echo "    - Use 'rlm-search' BEFORE reading files to save tokens"
echo "    - Use '/compact' in Claude every ~10 messages"
echo "    - Use '/clear' before starting new task steps"
echo "    - Test Telegram: 'gsd-telegram-test' before running long tasks"
echo ""
SCRIPTEOF

# --- 8c. AI Router (Multi-AI) ---
cat > scripts/ai_router.sh <<'SCRIPTEOF'
#!/bin/bash
# AI Router — Routes tasks to the most appropriate AI engine.
# Usage: gsd-route <task_type> "<prompt>"
#   task_type: map | test | boilerplate | reason (default)

set -euo pipefail

TASK_TYPE="${1:-reason}"
PROMPT="${2:-}"

if [[ -z "$PROMPT" ]]; then
    echo "Usage: gsd-route <task_type> '<prompt>'"
    echo "  Types: map, test, boilerplate, reason (default)"
    exit 1
fi

case "$TASK_TYPE" in
    map)
        echo "[Router] Large-scale mapping -> Gemini"
        if command -v gemini &>/dev/null; then
            gemini "$PROMPT"
        else
            echo "[Router] Gemini CLI not found. Falling back to Claude."
            claude -p "$PROMPT"
        fi
        ;;
    test|boilerplate)
        echo "[Router] Boilerplate/tests -> Local model (if available)"
        if command -v ollama &>/dev/null; then
            ollama run codellama "$PROMPT"
        else
            echo "[Router] Ollama not available (install with ENABLE_LOCAL_AI=true)."
            echo "[Router] Falling back to Claude."
            claude -p "$PROMPT"
        fi
        ;;
    reason|*)
        echo "[Router] Reasoning task -> Claude"
        claude -p "$PROMPT"
        ;;
esac
SCRIPTEOF

# --- 8d. Task Runner (DAG + Token Budget + Telegram) ---
cat > scripts/task_runner.sh <<'SCRIPTEOF'
#!/bin/bash
# Task Runner — Executes YAML-defined task DAGs with Claude.
# Features: dependency resolution, token budgeting, Telegram notifications.
# Usage: gsd-run <task.yaml>
#
# Expected YAML format:
#   steps:
#     - id: step1
#       prompt: "Do something"
#       depends_on: []
#     - id: step2
#       prompt: "Do something else"
#       depends_on: [step1]

set -euo pipefail

TASK_FILE="${1:-}"
if [[ -z "$TASK_FILE" || ! -f "$TASK_FILE" ]]; then
    echo "Usage: gsd-run <task.yaml>"
    echo ""
    echo "YAML format:"
    echo "  steps:"
    echo "    - id: step_name"
    echo "      prompt: 'Your prompt here'"
    echo "      depends_on: []"
    exit 1
fi

# Load environment
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
MAX_TOKEN_LIMIT="${MAX_TOKEN_LIMIT:-50000}"
PROJECT_NAME="${PROJECT_NAME:-sandbox}"
LOG_DIR="/workspace/logs"
mkdir -p "$LOG_DIR"

# --- Telegram Notification ---
send_telegram() {
    local msg="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="[$PROJECT_NAME] $msg" \
            -d parse_mode="Markdown" > /dev/null 2>&1 || true
    fi
}

# --- Token Budget Check ---
check_budget() {
    local today
    today=$(date +%F)
    local log_file="$LOG_DIR/tokens_${today}.log"
    local used_today=0

    if [[ -f "$log_file" ]]; then
        used_today=$(awk '{s+=$1} END {print s+0}' "$log_file")
    fi

    if (( used_today >= MAX_TOKEN_LIMIT )); then
        echo "BUDGET EXCEEDED: Used $used_today / $MAX_TOKEN_LIMIT tokens today."
        send_telegram "Budget exceeded: $used_today / $MAX_TOKEN_LIMIT tokens"
        exit 1
    fi
    echo "Budget: $used_today / $MAX_TOKEN_LIMIT tokens used today."
}

# --- Execute a single Claude step ---
run_claude_step() {
    local step_id="$1"
    local prompt_file="$2"
    local output_dir="$3"

    check_budget

    echo "Executing step: $step_id"
    local start_time
    start_time=$(date +%s)

    # Prepend RLM awareness to prompt
    {
        echo "[SYSTEM]: You have RAG tools available. Use 'rlm-search <query>' to find relevant code before reading files."
        echo ""
        cat "$prompt_file"
    } > "$output_dir/prompt_full.txt"

    # Run Claude
    claude -p "$(cat "$output_dir/prompt_full.txt")" \
        > "$output_dir/response.md" \
        2> "$output_dir/claude_stderr.log" || true

    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))

    # Estimate tokens (heuristic: ~4 chars per token)
    local chars
    chars=$(wc -c < "$output_dir/response.md" 2>/dev/null || echo 0)
    local prompt_chars
    prompt_chars=$(wc -c < "$output_dir/prompt_full.txt" 2>/dev/null || echo 0)
    local tokens=$(( (chars + prompt_chars) / 4 ))

    # Log token usage
    echo "$tokens" >> "$LOG_DIR/tokens_$(date +%F).log"
    echo "$tokens" > "$output_dir/tokens.txt"

    # Simple HTML transcript
    cat > "$output_dir/transcript.html" <<HTML
<!DOCTYPE html>
<html><head><title>Step: $step_id</title>
<style>body{font-family:monospace;padding:2em;max-width:900px;margin:auto}
pre{background:#f4f4f4;padding:1em;overflow-x:auto;border-radius:4px}</style>
</head><body>
<h1>Step: $step_id</h1>
<p>Duration: ${duration}s | Tokens (est): $tokens</p>
<h2>Prompt</h2>
<pre>$(cat "$output_dir/prompt_full.txt" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</pre>
<h2>Response</h2>
<pre>$(cat "$output_dir/response.md" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')</pre>
</body></html>
HTML

    # Copy transcript to dashboard
    cp "$output_dir/transcript.html" "/transcripts/${step_id}_$(date +%F_%H%M%S).html" 2>/dev/null || true

    send_telegram "Step *$step_id* done. Tokens: ~$tokens, Duration: ${duration}s"
    echo "Step $step_id completed (${duration}s, ~${tokens} tokens)."
}

# --- Main DAG Execution ---
echo ""
echo "=== Task Runner: $TASK_FILE ==="
echo ""

STEPS=$(yq -r '.steps[].id' "$TASK_FILE")
RUNTIME_DIR="runtime/steps"
mkdir -p "$RUNTIME_DIR"

MAX_ITERATIONS=100
iteration=0
all_done=false

while [[ "$all_done" != "true" && $iteration -lt $MAX_ITERATIONS ]]; do
    all_done=true
    progress=false

    for STEP in $STEPS; do
        STEP_DIR="$RUNTIME_DIR/$STEP"
        mkdir -p "$STEP_DIR"

        # Skip completed steps
        if [[ -f "$STEP_DIR/status" && "$(cat "$STEP_DIR/status")" == "DONE" ]]; then
            continue
        fi

        all_done=false

        # Check dependencies
        DEPS=$(yq -r ".steps[] | select(.id==\"$STEP\") | .depends_on[]?" "$TASK_FILE" 2>/dev/null || true)
        READY=true
        for D in $DEPS; do
            if [[ -n "$D" && "$D" != "null" ]]; then
                if [[ ! -f "$RUNTIME_DIR/$D/status" ]] || [[ "$(cat "$RUNTIME_DIR/$D/status")" != "DONE" ]]; then
                    READY=false
                    break
                fi
            fi
        done

        if [[ "$READY" == "true" ]]; then
            yq -r ".steps[] | select(.id==\"$STEP\") | .prompt" "$TASK_FILE" > "$STEP_DIR/prompt.txt"
            run_claude_step "$STEP" "$STEP_DIR/prompt.txt" "$STEP_DIR"
            echo "DONE" > "$STEP_DIR/status"
            progress=true
        fi
    done

    if [[ "$all_done" != "true" && "$progress" != "true" ]]; then
        echo "ERROR: Stuck — remaining steps have unmet dependencies."
        send_telegram "Task runner stuck: unmet dependencies"
        exit 1
    fi

    iteration=$((iteration + 1))
done

echo ""
echo "=== All steps complete ==="
send_telegram "All steps in $TASK_FILE completed."
SCRIPTEOF

# --- 8e. Transcript Renderer ---
cat > scripts/render_transcripts.sh <<'SCRIPTEOF'
#!/bin/bash
# Renders Claude session transcripts to browsable HTML using simonw's tool.
set -euo pipefail

ARCHIVE_DIR="/transcripts/archive"
mkdir -p "$ARCHIVE_DIR"

echo "Rendering Claude session transcripts..."

if command -v uvx &>/dev/null; then
    uvx claude-code-transcripts all -o "$ARCHIVE_DIR" 2>/dev/null || {
        echo "Note: claude-code-transcripts failed. Ensure sessions exist."
    }
    if [[ -f "$ARCHIVE_DIR/index.html" ]]; then
        cp "$ARCHIVE_DIR/index.html" /transcripts/index.html
        echo "Dashboard updated. View at http://localhost:$DASHBOARD_PORT"
    fi
else
    echo "uvx not found. Install uv first."
fi
SCRIPTEOF

# --- 8f. Telegram Test Utility ---
cat > scripts/test_telegram.sh <<'SCRIPTEOF'
#!/bin/bash
# Tests Telegram integration by sending a test message.
# Usage: gsd-telegram-test [message]

set -euo pipefail

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
PROJECT_NAME="${PROJECT_NAME:-sandbox}"

if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "ERROR: Telegram not configured."
    echo ""
    echo "To configure Telegram notifications:"
    echo "1. Create a bot via @BotFather on Telegram"
    echo "2. Get your chat ID (message @userinfobot)"
    echo "3. Add to .env file:"
    echo "   TELEGRAM_BOT_TOKEN=<your-bot-token>"
    echo "   TELEGRAM_CHAT_ID=<your-chat-id>"
    echo ""
    exit 1
fi

MESSAGE="${1:-Test message from AI Sandbox [$PROJECT_NAME]}"

echo "Sending test message to Telegram..."
echo "Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}... (truncated)"
echo "Chat ID: $TELEGRAM_CHAT_ID"
echo "Message: $MESSAGE"
echo ""

RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$MESSAGE" \
    -d parse_mode="Markdown")

if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "SUCCESS: Message sent!"
    echo ""
    echo "Check your Telegram app for the message."
    echo ""
    echo "Telegram notifications will be sent automatically when using:"
    echo "  - gsd-run <task.yaml>  (task automation)"
    echo ""
    if command -v ralph &>/dev/null; then
        echo "Ralph Orchestrator is installed. To use the same tokens:"
        echo "  ralph bot onboard --telegram"
        echo "  (provide the same bot token and chat ID)"
        echo ""
    fi
else
    echo "FAILED: Could not send message."
    echo ""
    echo "Response from Telegram API:"
    echo "$RESPONSE"
    echo ""
    echo "Common issues:"
    echo "  - Incorrect bot token or chat ID"
    echo "  - Bot hasn't been started (send /start to your bot)"
    echo "  - Network/firewall blocking api.telegram.org"
    echo ""
fi
SCRIPTEOF

chmod +x scripts/*.sh scripts/rlm/*.py

info "All runtime scripts written."

# ==========================================
# 9. WORKSPACE FILES (CLAUDE.md + sample task)
# ==========================================
header "9. Workspace Configuration Files"

# --- CLAUDE.md (project rules for AI sessions) ---
cat > workspace/CLAUDE.md <<'MDEOF'
# AI Sandbox — Project Rules

## Token Optimization
- ALWAYS use `rlm-search '<query>'` before reading files with `cat`.
- Use `rlm-map <file.py>` to understand structure before diving into code.
- Use `/compact` after ~10 messages to reduce context size.
- Use `/clear` before starting a new task step.

## Workflow
1. Search first: `rlm-search 'authentication logic'`
2. Map structure: `rlm-map src/auth.py`
3. Then implement changes with full context.

## Available Tools
- `rlm-index` — Rebuild the codebase vector search index
- `rlm-search '<query>'` — Semantic code search (top 5 results)
- `rlm-map <file.py>` — Python AST structure map
- `gsd-run <task.yaml>` — Execute YAML task DAG
- `gsd-route <type> '<prompt>'` — Route to best AI (claude/gemini/local)

## Coding Standards
- Run tests after every change.
- Commit frequently with descriptive messages.
- Keep functions small and focused.
MDEOF

# --- Sample task YAML ---
cat > workspace/sample-task.yaml <<'YAMLEOF'
# Sample task DAG for the GSD task runner.
# Run with: gsd-run sample-task.yaml

steps:
  - id: analyze
    prompt: |
      Analyze the current workspace structure. List all files, their purposes,
      and suggest improvements to the project organization.
    depends_on: []

  - id: implement
    prompt: |
      Based on the analysis from the previous step, create a README.md that
      documents the project structure and setup instructions.
    depends_on: [analyze]

  - id: review
    prompt: |
      Review the README.md that was just created. Check for accuracy,
      completeness, and suggest any final improvements.
    depends_on: [implement]
YAMLEOF

info "CLAUDE.md and sample-task.yaml written to workspace/"

# --- .claudeignore (keep Claude focused on repo code, not sandbox infra) ---
cat > workspace/.claudeignore <<'IGNEOF'
# ==============================================
# .claudeignore — AI Sandbox
# Keeps Claude focused on YOUR repo code.
# Place this in the root of any cloned repo, or
# leave it in /workspace to cover everything.
# ==============================================

# --- Sandbox infrastructure (not part of your repo) ---
/scripts/
/rag_db/
/transcripts/
/private/
/logs/
runtime/
sample-task.yaml

# --- Python ---
.venv/
venv/
env/
__pycache__/
*.pyc
*.pyo
*.egg-info/
dist/
build/
*.whl
.mypy_cache/
.ruff_cache/
.pytest_cache/
htmlcov/
.coverage
.tox/

# --- JavaScript / Node ---
node_modules/
.next/
.nuxt/
.output/
.svelte-kit/
bower_components/
*.min.js
*.min.css
*.bundle.js
*.chunk.js
*.map

# --- Package lock files (large, no useful context) ---
package-lock.json
yarn.lock
pnpm-lock.yaml
Pipfile.lock
poetry.lock
uv.lock
Gemfile.lock
composer.lock
Cargo.lock

# --- Compiled / binary ---
*.so
*.dylib
*.dll
*.o
*.a
*.class
*.jar
*.exe
*.bin
*.wasm

# --- Go ---
vendor/

# --- Rust ---
target/

# --- .NET ---
bin/
obj/
*.nupkg

# --- Data / models / media (large, not code) ---
*.csv
*.tsv
*.parquet
*.sqlite
*.db
*.pkl
*.h5
*.hdf5
*.onnx
*.pt
*.pth
*.safetensors
*.ckpt
*.tar.gz
*.zip
*.7z
*.rar
*.iso
*.img
*.mp4
*.mp3
*.wav
*.avi
*.mov
*.png
*.jpg
*.jpeg
*.gif
*.ico
*.svg
*.webp
*.bmp
*.tiff
*.pdf
*.ttf
*.woff
*.woff2
*.eot

# --- IDE / editor ---
.idea/
.vscode/
*.swp
*.swo
*~
.DS_Store
Thumbs.db

# --- Git internals ---
.git/

# --- Terraform / IaC state ---
.terraform/
*.tfstate
*.tfstate.backup

# --- Docker build context noise ---
Dockerfile
docker-compose.yml
.dockerignore
IGNEOF

info ".claudeignore written to workspace/"

# ==========================================
# 10. CLAUDE CODE DIRECTORY PRE-FLIGHT
# ==========================================
header "10. Claude Code Directory Pre-flight"

# CRITICAL: The docker-compose.yml mounts ${HOME}/.claude to /home/ai-worker/.claude
# If this directory doesn't exist or has wrong permissions, Claude Code will fail with
# "EACCES: permission denied, mkdir '/home/ai-worker/.claude/session-env/<session-id>'"
#
# We must ensure:
#   1. The host directory exists
#   2. Required subdirectories (session-env, shell-snapshots) exist
#   3. Permissions allow the container's ai-worker user (UID 1000) to write to it

info "Preparing Claude Code directory structure on host..."
mkdir -p "$HOME/.claude/session-env" "$HOME/.claude/shell-snapshots"
chmod 755 "$HOME/.claude" "$HOME/.claude/session-env" "$HOME/.claude/shell-snapshots" 2>/dev/null || true

# If running on Linux, ensure the container's ai-worker (UID 1000) can write.
# Instead of changing ownership (which breaks the host user on re-runs), we open
# permissions so both host user and container user can read/write.
# The container entrypoint will set final ownership for ai-worker inside the container.
if [[ "$OS_TYPE" == "Linux" ]]; then
    if [[ "$(id -u)" == "1000" ]]; then
        info "Host UID matches container UID (1000) — no permission fixup needed."
    else
        info "Host UID ($(id -u)) differs from container UID (1000)."
        info "Opening permissions on $HOME/.claude so both host and container can access it..."
        chmod -R a+rwX "$HOME/.claude" 2>/dev/null || {
            warn "Could not set permissions. Trying with sudo..."
            sudo chmod -R a+rwX "$HOME/.claude" 2>/dev/null || \
                warn "Could not fix permissions. The container entrypoint will attempt to fix this at startup."
        }
    fi
fi

info "Claude Code directory structure verified: $HOME/.claude"

# ==========================================
# 11. BUILD & LAUNCH
# ==========================================
header "11. Build & Launch"

if [[ "${ENABLE_LOCAL_AI:-false}" == "true" ]]; then
    warn "Local AI is enabled — Docker image will be ~4-6 GB larger. Build will be slow on first run."
fi
info "Building Docker image..."
$DOCKER_COMPOSE build

info "Starting services..."
# Start main sandbox (dashboard is in a separate profile, start explicitly if enabled)
$DOCKER_COMPOSE up -d ai-sandbox

if [[ "${ENABLE_DASHBOARD:-true}" == "true" ]]; then
    $DOCKER_COMPOSE --profile dashboard up -d
    info "Dashboard available at: http://localhost:$DASHBOARD_PORT"
fi

# --- Wait for container to be ready ---
info "Waiting for container to be ready..."
READY=false
for i in $(seq 1 30); do
    if $DOCKER_COMPOSE exec -T ai-sandbox test -f /tmp/.entrypoint-done 2>/dev/null; then
        READY=true
        break
    fi
    sleep 1
done
if [ "$READY" = true ]; then
    info "Container is ready."
else
    warn "Container did not signal readiness within 30s — tmux session may need manual retry."
fi

# --- Launch tmux session ---
if command -v tmux &>/dev/null; then
    SESSION_NAME="ai-sandbox-$PROJECT_NAME"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        warn "tmux session '$SESSION_NAME' already exists."
    else
        # Use a wrapper command that retries docker exec, so the tmux pane
        # stays alive even if the first attempt fails.
        tmux new-session -d -s "$SESSION_NAME" \
            "cd $BASE_DIR && while ! $DOCKER_COMPOSE exec -u ai-worker ai-sandbox bash -l; do echo 'Container not ready, retrying in 2s...'; sleep 2; done"
        info "tmux session created: $SESSION_NAME"
    fi
fi

# ==========================================
# SUMMARY
# ==========================================
echo ""
echo -e "${GREEN}${BOLD}=======================================${NC}"
echo -e "${GREEN}${BOLD}  AI Sandbox Deployed Successfully${NC}"
echo -e "${GREEN}${BOLD}=======================================${NC}"
echo ""
echo -e "  Project:     ${CYAN}$PROJECT_NAME${NC}"
echo -e "  Location:    ${CYAN}$BASE_DIR${NC}"
if [[ "${ENABLE_LOCAL_AI:-false}" == "true" ]]; then
    echo -e "  Local AI:    ${YELLOW}ENABLED${NC} (sentence-transformers + PyTorch + Ollama)"
else
    echo -e "  Local AI:    standard (lightweight ONNX embeddings)"
fi
echo ""
echo -e "  ${BOLD}Access:${NC}"
echo -e "    tmux:      ${YELLOW}tmux attach -t ai-sandbox-$PROJECT_NAME${NC}"
echo -e "    docker:    ${YELLOW}docker exec -it -u ai-worker ai-sandbox-$PROJECT_NAME bash -l${NC}"
echo -e "    dashboard: ${YELLOW}http://localhost:$DASHBOARD_PORT${NC}"
echo ""
echo -e "  ${BOLD}Container user:${NC} ${CYAN}ai-worker${NC} (non-root, Claude permissions mode compatible)"
echo ""
echo -e "  ${BOLD}First steps inside the container:${NC}"
echo -e "    1. ${YELLOW}claude login${NC}         — Link your Claude Pro plan"
echo -e "    2. ${YELLOW}rlm-index${NC}            — Build the code search index"
echo -e "    3. ${YELLOW}claude${NC}               — Start coding!"
echo -e "    4. ${YELLOW}gsd-run sample-task.yaml${NC} — Try the task runner"
echo ""
echo -e "  ${BOLD}Workspace:${NC}"
echo -e "    Code goes in:  ${CYAN}$BASE_DIR/workspace/${NC}"
echo -e "    Private files:  ${CYAN}$BASE_DIR/private/${NC} (read-only in container)"
echo -e "    Logs:           ${CYAN}$BASE_DIR/logs/${NC}"
echo ""