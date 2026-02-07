# TASK_LIST — Sprint Plan

## Sprint 1 — Core CLI & Loop Skeleton
:::task-stub{title="Bootstrap CLI entrypoint and command structure"}
Create `src/cli/main.py` (or equivalent) to provide `init`, `run`, `status`, `resume`, `review`, `export` commands. Implement argument parsing and pass-through to core modules. Add basic help output and version command.
:::

:::task-stub{title="Implement loop orchestrator with phase interface"}
Create `src/core/loop.py` with a `LoopEngine` that runs phases in order. Define a `Phase` interface (e.g., `run(context) -> context`) and wire a minimal flow (plan → read → edit → reflect). Add minimal context object.
:::

:::task-stub{title="Config loader for providers and strategies"}
Add config loading in `src/core/config.py` to parse a `config.toml` or `config.yaml`. Include provider selection, token budgets, and enabled strategies. Ensure CLI can override config via flags.
:::

## Sprint 2 — Provider Abstraction
:::task-stub{title="Create LLM provider abstraction layer"}
Add `src/llm/base.py` with a `Provider` abstract class (methods: `complete`, `chat`, `embeddings`). Implement factory and registration for providers.
:::

:::task-stub{title="Implement OpenAI provider adapter"}
Add `src/llm/providers/openai.py`. Map config fields to API calls, handle retries and rate limits. Provide a mock/test mode to avoid external calls in tests.
:::

:::task-stub{title="Implement local provider adapter (Ollama/llama.cpp)"}
Add `src/llm/providers/local.py`. Support local HTTP API endpoints and streaming. Provide config for base URL and model name.
:::

## Sprint 3 — Token Minimization Strategies
:::task-stub{title="Add diff-based context extraction"}
Create `src/context/diff.py` to compute git diffs and return compact summaries. Integrate into loop context assembly to avoid full file loads.
:::

:::task-stub{title="Implement minimal file reader and snippet extractor"}
Add `src/context/reader.py` to read only relevant lines around search hits or diff hunks. Provide “read budget” enforcement in tokens/lines.
:::

:::task-stub{title="Git hook integration for summaries"}
Add `src/git/hooks.py` to install commit-msg or post-commit hooks that write a summary file with changed files, diff stats, and optional LLM-generated summary. Ensure hooks are optional and idempotent.
:::

## Sprint 4 — Retrieval & Memory
:::task-stub{title="Add searchable index for code and summaries"}
Create `src/context/index.py` to build a local index (e.g., sqlite + FTS or simple BM25). Support searching by keywords to pre-select files for context.
:::

:::task-stub{title="Summarization store for modules and runs"}
Add `src/storage/summaries.py` to store module summaries and run summaries. Ensure loop can query summaries when token budgets are tight.
:::

## Sprint 5 — Evaluation & UX
:::task-stub{title="Add evaluation harness for token usage"}
Create `src/eval/token_report.py` to report prompt/response token counts per run and per phase. Add CLI `report` command to print diffs from baseline.
:::

:::task-stub{title="Add review mode for patch approval"}
Implement `src/cli/review.py` to display diffs and allow approval/skip. Integrate into loop as a manual gate before commit.
:::
