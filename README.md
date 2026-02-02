# AI Sandbox Factory

A comprehensive Docker-based development environment deployment script for AI-assisted coding workflows with Claude Code, multi-AI routing, RAG capabilities, and automated task orchestration.

---

## Motivation

The original Ralhp Wiggum loop (https://ghuntley.com/ralph/) and its descendants and similar autonomous loops can be incredibly efficient at generating and completing code projects.
They require a high level of autonomy and hence security is key.
Setting up Docker containers for each project can be tedious. This is what this script is trying to address.

---

## TL;DR

**`deploy-ai-sandbox.sh`** is a one-command deployment script that creates a fully-equipped Docker container optimized for AI-assisted development, especially for highly autonomous ai-driven development. It automatically:

- Detects your platform (macOS, Arch Linux, Debian/Ubuntu) and installs required dependencies
- Sets up a Docker-based development environment with Python, Node.js, and optional language runtimes (Go, .NET, Rust, TypeScript)
- Configures Claude Code CLI integration with your Anthropic API key
- Configures Gemini integration with your Gemini API key
- Integrates status update message via Telegram with your Telegram bot token
- Provides RAG/vector search capabilities using ChromaDB and sentence-transformers (Reduces token consumption. Read more about the general idea here: https://arxiv.org/pdf/2512.24601)
- Includes a YAML-driven DAG task runner with token budgeting and optional Telegram notifications
- Sets up a web dashboard for viewing AI interaction transcripts
- Creates workspace rules (`CLAUDE.md`) to optimize AI coding sessions
- Supports multi-AI routing (Claude, Gemini, local models via Ollama)
- Includes installation option for GSD (https://github.com/glittercowboy/get-shit-done)
- Includes installation option for ralph-orchestrator (https://github.com/mikeyobrien/ralph-orchestrator)

This is version 1.0.0 - expect some rough edges. Happy to listen to your feedback.

**Quick start:**
```bash
./deploy-ai-sandbox.sh my-project-name
```

This creates an isolated, reproducible AI development environment in `~/ai-sandbox-projects/my-project-name/` with everything you need to start coding with AI assistance.

---

## User Manual & Useful Commands

### Prerequisites

- **macOS**: Homebrew and Docker Desktop installed
- **Linux**: Root/sudo access for package installation
- **Minimum 10GB free disk space** (more if enabling local AI models)

### Installation

1. **Download the script:**
   ```bash
   curl -O https://raw.githubusercontent.com/your-repo/deploy-ai-sandbox.sh
   chmod +x deploy-ai-sandbox.sh
   ```

2. **Run the deployment:**
   ```bash
   ./deploy-ai-sandbox.sh [project-name]
   ```
   
   If no project name is provided, it defaults to `ai-sandbox`.

3. **During setup, you'll be prompted for:**
   - Anthropic API key (for Claude)
   - Google/Gemini API key (optional)
   - Telegram bot credentials (optional, for notifications)
   - Daily token budget (default: 50,000 tokens)
   - Language runtime preferences (Go, .NET, TypeScript, Rust)
   - Local AI installation (sentence-transformers, PyTorch, Ollama)

### Accessing Your Sandbox

After deployment, you have three ways to access the container:

**1. Via Docker exec:**
```bash
docker exec -it -u ai-worker ai-sandbox-my-project-name bash -l
```

Then inside the container, create a tmux session:
```bash
tmux new -s ai-sandbox-my-project-name
```

**2. Via tmux (recommended):**
After tmux has been started:
```bash
tmux attach -t ai-sandbox-my-project-name
```

**3. Via web dashboard:**
```
http://localhost:7337  # or next available port
```

### Essential Container Commands

Once inside the container:

**Claude Code Setup:**
```bash
# Link your Claude Pro account
claude login

# Start a coding session
claude
```

**RAG/Code Search:**
```bash
# Index your workspace for vector search
rlm-index

# Query the codebase semantically
rlm-query "how does authentication work?"
```

**Task Runner:**
```bash
# Run a YAML-defined task DAG
gsd-run sample-task.yaml

# Example task execution (with token budgeting)
gsd-run workspace/my-analysis.yaml
```

**Local AI (if enabled):**
```bash
# Start Ollama
ollama serve &

# Pull and run a model
ollama pull llama3.2
ollama run llama3.2
```

**Multi-AI Routing:**
```bash
# Environment is pre-configured with:
# - Claude (via ANTHROPIC_API_KEY)
# - Gemini (via GOOGLE_API_KEY)  
# - Local models (via Ollama)
```

### Project Structure

```
~/ai-sandbox-projects/my-project-name/
├── workspace/          # Your code goes here
│   ├── CLAUDE.md      # AI coding guidelines
│   ├── sample-task.yaml
│   └── .claudeignore  # Files to exclude from Claude context
├── private/           # Read-only sensitive files
├── logs/              # Application logs
├── transcripts/       # AI interaction history
├── rag_db/            # ChromaDB vector database
├── scripts/           # Utility scripts
├── ssh/               # SSH keys for Git
├── .env               # Environment configuration
├── Dockerfile
└── docker-compose.yml
```

### Configuration Files

**`.env`** - Main configuration:
- `ANTHROPIC_API_KEY` - Claude API key
- `GOOGLE_API_KEY` - Gemini API key (optional)
- `MAX_DAILY_TOKENS` - Token budget limit
- `TELEGRAM_BOT_TOKEN` - Bot token for alerts
- `TELEGRAM_CHAT_ID` - Chat ID for notifications
- `ENABLE_LOCAL_AI` - Install PyTorch/transformers (true/false)
- `ENABLE_DASHBOARD` - Run transcript dashboard (true/false)
- `INSTALL_*` - Language runtime toggles

**`CLAUDE.md`** - AI session optimization rules:
- Defines coding standards, preferences, and workflow
- Claude Code automatically reads this file when working in the directory
- Customize based on your project needs

**`sample-task.yaml`** - Example DAG workflow:
```yaml
steps:
  - id: analyze
    prompt: "Analyze the workspace..."
    depends_on: []
  
  - id: implement
    prompt: "Create README based on analysis..."
    depends_on: [analyze]
```

### Maintenance Commands

**Stop the sandbox:**
```bash
cd ~/ai-sandbox-projects/my-project-name
docker compose down
```

**Restart services:**
```bash
docker compose restart
```

**View logs:**
```bash
docker compose logs -f ai-sandbox
```

**Rebuild after config changes:**
```bash
docker compose build
docker compose up -d
```

**Clean up completely:**
```bash
docker compose down -v
rm -rf ~/ai-sandbox-projects/my-project-name
```

### SSH Key Management

The script handles SSH keys for Git operations inside the container:

- **Existing key**: Copies from `~/.ssh/id_ed25519` (configurable via `SSH_KEY_PATH`)
- **New key**: Generates `ed25519` key if none found
- **After generation**: Add the public key to GitHub/GitLab/etc:
  ```bash
  cat ~/ai-sandbox-projects/my-project-name/ssh/id_rsa.pub
  ```

### Dashboard Features

The web dashboard (nginx-based) provides:
- Real-time view of AI interaction transcripts
- Archived conversation history
- JSON-formatted API responses
- Accessible at `http://localhost:7337` (or next available port)

### Token Budget Management

The GSD task runner enforces daily token limits:
- Tracks usage across all AI calls
- Fails gracefully when budget exceeded
- Sends Telegram alerts (if configured)
- Budget resets daily at midnight UTC

### Troubleshooting

**Docker daemon not starting (macOS):**
```bash
open -a Docker
# Wait 30-60 seconds for Docker to initialize
```

**Permission denied errors:**
```bash
# Ensure you're in the docker group (Linux)
sudo usermod -aG docker $USER
# Log out and back in
```

**API version mismatch:**
```bash
export DOCKER_API_VERSION=1.41
./deploy-ai-sandbox.sh my-project
```

**Port 7337 already in use:**
The script automatically finds the next available port.

**Large image size:**
- Without local AI: ~2-3GB
- With local AI: ~6-8GB (PyTorch, transformers, models)

---

## Technical Description

### Architecture Overview

`deploy-ai-sandbox.sh` is a production-grade provisioning script that orchestrates a complete AI development environment using Docker containerization. It implements a multi-layer architecture:

1. **Host System Layer** - Platform detection and dependency management
2. **Container Layer** - Isolated development environment with specific tooling
3. **Service Layer** - AI routing, RAG indexing, and task orchestration
4. **Interface Layer** - CLI, web dashboard, and API integrations

### Platform Detection & Dependency Installation

**Supported Platforms:**
- macOS (Darwin) - Uses Homebrew for package management
- Arch Linux - Uses Pacman
- Debian/Ubuntu - Uses APT with official Docker repositories

**Host Dependencies:**
- Docker Engine or Docker Desktop
- Docker Compose (v2 plugin or standalone)
- jq, yq (YAML/JSON processors)
- tmux (terminal multiplexer)
- git, curl, openssh
- Python 3.11+ (for socket API queries)

**Docker API Version Handling:**
The script includes sophisticated Docker version compatibility logic:
- Queries daemon via Unix socket (`/var/run/docker.sock`) to bypass CLI version checks
- Automatically pins `DOCKER_API_VERSION` when CLI/daemon mismatch detected
- Falls back to parsing error messages if socket query fails
- Prevents cryptic "client version too new" errors

### Container Build Process

**Base Image:** Ubuntu 24.04 LTS (Jammy)

**Build Stages:**
1. System packages (Python, Node.js, Git, SSH, build tools)
2. Python environment via `uv` (fast package manager)
3. Node.js LTS (via NodeSource repository)
4. Optional language runtimes (Go, .NET 8, Rust, TypeScript)
5. AI tooling (Claude Code, ChromaDB, sentence-transformers)
6. Conditional local AI stack (PyTorch, Ollama, ~4GB additional size)

**Non-root User:**
- Container runs as `ai-worker` (UID 1000) for security
- Compatible with Claude Code's permission requirements
- Home directory: `/home/ai-worker`

**Volume Mounts:**
```yaml
volumes:
  - ./workspace:/home/ai-worker/workspace      # Read-write workspace
  - ./private:/home/ai-worker/private:ro       # Read-only secrets
  - ./logs:/home/ai-worker/logs                # Application logs
  - ./rag_db:/home/ai-worker/rag_db            # Persistent vector DB
  - ./transcripts:/home/ai-worker/transcripts  # AI conversation logs
  - ./ssh:/home/ai-worker/.ssh:ro              # SSH keys
```

### Environment Configuration

**.env Generation:**
The script interactively builds a `.env` file with:
- API keys (Anthropic, Google/Gemini)
- Telegram bot credentials for notifications
- Token budget limits (default: 50,000/day)
- Feature flags (dashboard, local AI, language runtimes)
- ChromaDB settings
- Dashboard port (auto-detected, starts at 7337)

**Environment Injection:**
- `.env` passed to `docker-compose.yml` via `env_file` directive
- Available to all container processes
- No secrets committed to version control

### Docker Compose Services

**1. ai-sandbox (main service):**
- Runs the development container
- Exposes workspace and tooling
- Includes health checks
- Automatic restart policy

**2. dashboard (profile: dashboard):**
- Nginx web server
- Serves transcript files
- Auto-index enabled for browsing
- Optional service (can be disabled via `ENABLE_DASHBOARD=false`)

### RAG/Vector Search Implementation

**Technology Stack:**
- **ChromaDB**: Vector database for semantic search
- **sentence-transformers**: Embedding model for code/text vectorization
- **ONNX Runtime**: Lightweight inference (default mode)
- **PyTorch + transformers**: Full ML stack (optional, for local AI)

**Scripts Provided:**

**`rlm-index`**: Recursive code indexer
```bash
#!/usr/bin/env bash
# Indexes all code files in workspace
# Creates embeddings via sentence-transformers
# Stores in ChromaDB at ~/rag_db/
find workspace -type f -name "*.py" -o -name "*.js" -o -name "*.ts" | \
  xargs python3 scripts/rlm/embed.py
```

**`rlm-query`**: Semantic search interface
```bash
#!/usr/bin/env bash
# Query: "authentication implementation"
# Returns: Top 5 relevant code chunks with context
python3 scripts/rlm/query.py "$1"
```

**Embedding Storage:**
- Default collection: `code-embeddings`
- Metadata: file path, language, line numbers
- Distance metric: Cosine similarity
- Persistent storage in `rag_db/` volume

### Multi-AI Routing

**Claude (Anthropic):**
- Primary AI via `claude` CLI
- API key: `ANTHROPIC_API_KEY`
- Used by GSD task runner by default
- Supports file context, artifacts, tools

**Gemini (Google):**
- Secondary AI for diversity
- API key: `GOOGLE_API_KEY`
- Can be used via `gsd-run` with `--model gemini-2.0-flash`
- Multimodal capabilities

**Local Models (Ollama):**
- Fully offline inference
- Installed when `ENABLE_LOCAL_AI=true`
- Models: Llama 3.2, Phi-3, Mistral, etc.
- Runs on CPU by default (GPU passthrough possible)

### GSD Task Runner

**Design:**
- YAML-defined Directed Acyclic Graphs (DAGs)
- Each step has: `id`, `prompt`, `depends_on` list
- Topological execution order
- Token budget enforcement
- Telegram notifications on completion/failure

**Token Budgeting:**
```python
# Pseudocode
daily_usage = read_from_state()
if daily_usage + estimated_tokens > MAX_DAILY_TOKENS:
    send_telegram_alert("Budget exceeded")
    raise BudgetError
else:
    execute_step()
    update_state(daily_usage + actual_tokens)
```

**State Persistence:**
- JSON file: `workspace/runtime/gsd_state.json`
- Tracks per-day usage
- Resets at midnight UTC

**Execution Flow:**
1. Parse YAML, validate structure
2. Build dependency graph
3. For each step in topological order:
   - Check token budget
   - Execute prompt against configured AI
   - Log transcript to `transcripts/`
   - Update state
4. Send summary notification (if Telegram configured)

### CLAUDE.md Workspace Rules

**Purpose:**
- Define AI coding session guidelines
- Set project-specific standards
- Enforce conventions automatically
- Claude Code reads this file on session start

**Sections:**
- **Project Overview**: High-level description
- **File Organization**: Directory structure expectations
- **Coding Conventions**: Language-specific standards
- **Testing Requirements**: Test-driven development rules
- **Git Workflow**: Commit message formats, branching strategy

**Example Rule:**
```markdown
## Testing
- Write unit tests before implementing features
- Minimum 80% code coverage
- Run `pytest` before every commit
```

Claude automatically applies these rules when generating/reviewing code.

### Transcript Dashboard

**Implementation:**
- **Server**: Nginx 1.24 (Alpine-based image)
- **Configuration**: Auto-index enabled, JSON MIME types
- **Content**: Real-time AI conversation logs in JSON format
- **Access**: HTTP on port 7337+ (auto-discovered)

**File Structure:**
```
transcripts/
├── 2025-02-01_session_abc123.json
├── 2025-02-01_task_xyz789.json
└── archive/
    └── 2025-01_archive.tar.gz
```

**Dashboard Features:**
- Directory browsing of all transcripts
- Click-to-view JSON responses
- Archive access for historical analysis
- Syntax highlighting (browser-dependent)

### Security Considerations

**SSH Key Handling:**
- Keys copied to container, never created inside
- Permissions enforced: `chmod 600`
- Public key displayed for user to add to Git providers
- Keys mounted read-only in container

**API Key Storage:**
- Stored in `.env` (gitignored by default)
- Not logged to stdout
- Passed to container via environment variables only
- No hardcoded secrets in any file

**Container Isolation:**
- Non-root user (`ai-worker`)
- Limited volume mounts (no host root access)
- No privileged mode
- Network isolation via Docker bridge

**Token Budget:**
- Prevents runaway costs
- Enforced before each AI call
- Fails gracefully with notifications
- User-configurable limits

### Performance Optimizations

**Docker Layer Caching:**
- System packages installed before user-specific config
- Language runtimes in conditional layers
- Minimal layer rebuilds on `.env` changes

**Dependency Management:**
- `uv` for Python (10-100x faster than pip)
- Node.js via binary download (fast, reproducible)
- Pre-compiled binaries where possible

**Vector Search:**
- ONNX Runtime by default (CPU-optimized, small)
- PyTorch optional (better accuracy, 4GB+ larger)
- Incremental indexing (only new/changed files)

**tmux Session Management:**
- Single persistent session per project
- Avoids recreation on script re-runs
- Background service keeps container alive

### Extensibility

**Adding Language Runtimes:**
Edit Dockerfile build args:
```dockerfile
ARG INSTALL_ELIXIR=false
RUN if [ "$INSTALL_ELIXIR" = "true" ]; then \
    apt-get install -y elixir; \
fi
```

**Custom AI Providers:**
Add to `.env` and update routing logic in `scripts/rlm/router.py`:
```python
if provider == "openai":
    return OpenAIClient(api_key=os.getenv("OPENAI_API_KEY"))
```

**Additional Services:**
Extend `docker-compose.yml`:
```yaml
services:
  postgres:
    image: postgres:16
    volumes:
      - pgdata:/var/lib/postgresql/data
```

### Known Limitations

1. **macOS Docker Desktop Required**: Engine not available via package manager
2. **ARM64 Compatibility**: Local AI (PyTorch/Ollama) may have reduced performance on ARM
3. **Token Budget Accuracy**: Estimated tokens may differ from actual API usage (~5-10% variance)
4. **Dashboard Security**: No authentication by default (localhost only, add reverse proxy for production)
5. **Single Project Per Container**: Name conflicts require manual cleanup

### Future Enhancements

- **GitHub Actions Integration**: CI/CD with AI-assisted code review
- **Multi-container Orchestration**: Kubernetes manifests for scaling
- **Built-in Evaluation**: Automated testing of AI-generated code
- **Fine-tuning Pipeline**: Custom model training from project history
- **Collaborative Mode**: Shared workspace for team AI sessions

---

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test on macOS, Arch, and Debian/Ubuntu
4. Submit a pull request with detailed description

## License

MIT License - See LICENSE file for details

## Support

- **Issues**: GitHub Issues tracker
- **Discussions**: GitHub Discussions for questions
- **Documentation**: https://docs.claude.com (for Claude Code specifics)

---

**Version**: 1.0.0  
**Last Updated**: February 2025  
**Maintainer**: madams0815 (Michael Adams)
