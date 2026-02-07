# PRD — Ralph Wiggum–style Autonomous Coding Loop (Python)

## 1. Overview
Build a Python CLI that implements a Ralph Wiggum–style autonomous software creation loop. It should support multiple LLM providers (Claude, ChatGPT, local models), optimize token usage, and employ code-reading and commit-based workflows (hooks) to minimize model context cost.

## 2. Goals
- Implement an agentic loop with configurable phases (plan → read → edit → test → commit → reflect).
- Multi-provider LLM abstraction (OpenAI, Anthropic, local via Ollama/llama.cpp).
- Token-minimizing strategies: commit hooks, retrieval/rag for code, diff-based context, selective file reads, semantic search.
- CLI-first, scriptable, minimal dependencies.

## 3. Non‑Goals
- Full IDE integration (out of MVP scope).
- Complex GUI.
- Full autonomous deployment pipelines.

## 4. Users & Use Cases
- Solo developers prototyping tools.
- Teams experimenting with agent loops.
- Researchers exploring token savings in coding agents.

## 5. Key Requirements
### Functional
- CLI commands: `init`, `run`, `status`, `resume`, `review`, `export`.
- Configurable providers and models in a single config file (YAML/TOML).
- Pluggable loop phases with clear interfaces.
- Git integration for commits and hooks.
- Memory system for summaries and retrieval (local index).

### Non‑Functional
- Fast startup (< 2s for CLI commands).
- Deterministic logs and reproducibility.
- Offline-friendly when using local models.

## 6. Architecture
- `cli/`: entrypoints, command parsing.
- `core/loop.py`: main loop orchestrator.
- `core/strategies/`: token-optimization strategies.
- `llm/providers/`: adapters (OpenAI, Anthropic, Local).
- `context/`: retrieval, summarization, diffing.
- `git/`: hooks, commit metadata, context extraction.
- `storage/`: run logs, artifacts, summaries.

## 7. Token Optimization Strategies
- Git commit hooks to store metadata summaries and diffs instead of full file contents.
- “Read Minimal”: only load file snippets relevant to current issue or diff.
- Embedding search / lexical search to pre-filter files.
- Windowing: local summarization of large modules.

## 8. MVP Scope
- CLI with run loop.
- At least 2 providers (OpenAI + local).
- Git hook–based summaries and diff-driven context.
- Basic persistence of run history.

## 9. Risks & Mitigations
- Provider API drift → abstract adapter layer.
- Token overuse → hard limits and strategy toggles.
- Hallucinated changes → validation hooks, diff review mode.

## 10. Success Metrics
- % reduction in tokens per change vs baseline.
- Run completion rate.
- Provider interoperability without code changes.

## 11. Milestones
- M1: CLI + providers + loop skeleton.
- M2: token strategies + git hooks.
- M3: retrieval + summary store + eval harness.
