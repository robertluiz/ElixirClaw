# Napkin Runbook

## Curation Rules
- Re-prioritize on every read.
- Keep recurring, high-value notes only.
- Max 10 items per category.
- Each item includes date + "Do instead".

## Execution & Validation (Highest Priority)
1. **[2026-03-25] Windows bootstrap needs the Cozo native rebuild**
   Do instead: run `npm rebuild cozo-node` as part of setup before starting the app or login tasks.
2. **[2026-03-25] Bootstrap files must preserve local edits**
   Do instead: create `config/config.toml` and `.vscode/tasks.json` only when missing or already identical.

## Shell & Command Reliability
1. **[2026-03-25] Prefer Mix tasks for Elixir bootstrap steps**
   Do instead: execute `deps.get` and `compile` through `Mix.Task.run/2`, leaving shell commands only for npm.

## User Directives
1. **[2026-03-25] Implement in XP-sized, test-backed steps**
   Do instead: keep orchestration thin, cover bootstrap behavior with tests, and refactor behind small helpers.