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
