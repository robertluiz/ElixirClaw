# ElixirClaw — Issues & Gotchas

## Known Gotchas
- `mix new . --force --app elixir_claw --sup` — MUST use `.` (not `elixir_claw`) to scaffold in current dir, and `--force` because .git/ and .sisyphus/ already exist
- `conduit_mcp` does NOT exist — use `hermes_mcp` instead
- Codex API is NOT OpenAI-compatible — uses Responses API with SSE named events on port 1455
- Windows paths: use `test/fixtures/opencode/` not `/tmp/` for temporary test files
- No tmux available — use Bash with piped input for CLI QA scenarios
- Task 6 and Task 4 both touch `test/support/mocks.ex` — Task 4 defines mocks, Task 6 configures them; run sequentially or merge carefully

## Task 2 Issues
- `elixir-ls` is not installed in this workspace, so `lsp_diagnostics` cannot be used for Elixir verification; rely on `mix test` and `mix compile --warnings-as-errors` instead.
- Running multiple `mix test` commands in parallel on Windows can emit build-directory lock messages; capture evidence sequentially if clean logs are required.

## Task 3 Issues
- `Ecto.Migrator.run/4` against `:memory:` SQLite under sandbox did not provide a stable `schema_migrations` table for per-test setup, so schema tests use a shared sandbox connection with explicit table creation.
- First pass of the messages migration failed because SQLite does not support `create constraint/3` via `ALTER TABLE`; fixed by using raw `CREATE TABLE` SQL with inline `CHECK`.

## F2 Code Quality Audit Warnings
- `lib/elixir_claw/channels/telegram.ex`: `process_update_call/2` lacks a `with ... else` fallback; invalid or unsupported updates can bubble up as `{:error, reason}` and break `handle_call/3`'s `{reply, next_state}` match.
- `lib/elixir_claw/channels/discord.ex`: direct-message handling calls `agent_loop.process_message/2` synchronously inside the GenServer, which can block the channel process; `!new` also leaves stale route/subscription entries in state.
- `lib/elixir_claw/config/loader.ex`: `build_config/1` uses a broad `rescue` and returns `Exception.message/1` without logging, which hides debugging context.
- `lib/elixir_claw/resilience/circuit_breaker.ex`: half-open mode sets `in_flight?` but does not enforce single-probe admission, so multiple concurrent half-open calls are possible.

## F4 Scope Fidelity Audit Issues
- Final scope audit result is REJECT because the required MCP files `lib/elixir_claw/mcp/registry.ex` and `lib/elixir_claw/mcp/tool_executor.ex` are missing; current MCP files are `http_client.ex`, `stdio_client.ex`, `supervisor.ex`, and `tool_wrapper.ex`.
- `elixir-ls` is still not installed, so `lsp_diagnostics` cannot verify Elixir files in this workspace; audit verification relied on direct file inspection plus the full passing test suite.
