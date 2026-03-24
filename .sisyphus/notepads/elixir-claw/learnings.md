# ElixirClaw — Learnings

## Project Conventions
- All files under `lib/elixir_claw/` (not `lib/elixir_claw/elixir_claw/`)
- Module prefix: `ElixirClaw.*`
- TDD mandatory: write failing test FIRST, then implementation
- Platform: Windows-first (no /tmp, no tmux, use Git Bash paths)
- Mix project lives at repo root: `C:\projects\ElixirClaw\`

## Canonical File Paths
| Module | File Path |
|--------|-----------|
| `ElixirClaw.Provider` | `lib/elixir_claw/providers/provider.ex` |
| `ElixirClaw.Channel` | `lib/elixir_claw/channels/channel.ex` |
| `ElixirClaw.Tool` | `lib/elixir_claw/tools/tool.ex` |
| `ElixirClaw.Types.Message` | `lib/elixir_claw/types/message.ex` |
| `ElixirClaw.Types.Session` | `lib/elixir_claw/types/session.ex` |
| `ElixirClaw.Session.Manager` | `lib/elixir_claw/session/session_manager.ex` |
| `ElixirClaw.Session.Worker` | `lib/elixir_claw/session/worker.ex` |
| `ElixirClaw.Bus.MessageBus` | `lib/elixir_claw/bus/message_bus.ex` |
| `ElixirClaw.Agent.ContextBuilder` | `lib/elixir_claw/agent/context_builder.ex` |
| `ElixirClaw.Agent.Loop` | `lib/elixir_claw/agent/agent_loop.ex` |
| `ElixirClaw.Config` | `lib/elixir_claw/config.ex` |
| `ElixirClaw.Repo` | `lib/elixir_claw/repo.ex` |

## Key Dependencies
```elixir
{:req, "~> 0.5"}, {:req_llm, "~> 1.8"}, {:telegex, "~> 1.8"}, {:nostrum, "~> 0.10", runtime: false},
{:hermes_mcp, "~> 0.14"}, {:jason, "~> 1.4"}, {:ecto_sqlite3, "~> 0.15"},
{:toml, "~> 0.7"}, {:oauth2, "~> 2.1"}, {:phoenix_pubsub, "~> 2.1"},
{:mox, "~> 1.1", only: :test}, {:bypass, "~> 2.1", only: :test}
```

## Task 1 Learnings (Scaffold)
- `req_llm` is at `~> 1.8`, NOT `~> 0.3` (plan had wrong version)
- `mix new` in Elixir 1.19 does NOT support `--force` flag — removed it; works fine since only `.git/` and `.sisyphus/` exist
- `nostrum` auto-starts and REQUIRES a bot token → must use `runtime: false` to prevent crash in dev/test
- Elixir 1.19.5 / OTP 28 is installed via Chocolatey on Windows
- `elixir` / `mix` are NOT in Git Bash PATH — must use full path: `C:/ProgramData/chocolatey/lib/Elixir/tools/bin/mix.bat`
- First `mix test` in test env may fail with `telegex` compilation order issue — force-compiling `plug` then `telegex` fixes it
- All dependency warnings are from upstream packages (toml, nostrum, tesla, bypass) — our code compiles clean

## Task 2 Learnings (Config)
- `Toml.decode/1` defaults to string keys, which avoids unsafe runtime atom creation and fits config validation well.
- Supporting both array-of-tables (`[[providers]]`) and named tables (`[providers.openai]`) is easiest by normalizing maps/lists into a common collection shape.
- Root scalar keys can collide with nested tables (for example `rate_limit = 60` vs `[rate_limit] ...`), so nested lookup must avoid `get_in/2` on scalar values.
- Provider configs can be stored as structs and still satisfy `%{name: ...}` style assertions because structs are maps at match time.

## Task 3 Learnings (Ecto + SQLite)
- SQLite rejects `ALTER TABLE ADD CONSTRAINT`, so message role validation must be expressed inline in `CREATE TABLE` for migrations.
- `:memory:` SQLite plus `Ecto.Adapters.SQL.Sandbox` is simplest in sync tests when one shared sandbox connection owns the database lifecycle.
- For in-memory SQLite tests, creating tables once on the shared sandbox connection and truncating rows between tests avoids per-connection schema drift.

## Task 7 Learnings (Session Manager)
- Per-session processes fit cleanly as `DynamicSupervisor` children registered through `{:via, Registry, {ElixirClaw.SessionRegistry, session_id}}`, keeping lookup cheap without a global GenServer bottleneck.
- Sandbox-owned worker processes should be allowed at `init/1`; test cleanup should terminate session workers directly instead of calling persistence-heavy APIs after the owning test process exits.
- With `System.monotonic_time(:second)`, rate limiting is easiest as a rolling timestamp window pruned on each `record_call/2`, while accumulated token totals stay authoritative in both worker state and the persisted session row.

## Task 8 Learnings
- `Phoenix.PubSub` fits the channel↔orchestrator boundary cleanly as a supervised bus child, avoiding a single mailbox bottleneck while keeping fan-out semantics trivial to test.
- Recursive payload sanitization needs an explicit `token_count` carve-out; otherwise a broad `/token/i` secret filter strips useful stream usage metadata along with actual secrets.

## Task 9 Learnings
- Context window assembly is simplest when system prompt, capped skills, and sanitized latest user input are treated as mandatory reservations before allocating any history budget.
- To preserve newest context under a hard token cap while still signaling truncation, select history newest-first, then evict the oldest retained history message as needed to make room for a single `[Earlier conversation summarized]` system marker.
- Existing `%Message{token_count: ...}` values are not reliable for prompt budgeting in tests; recomputing token heuristics from `content` keeps `estimate_tokens/1`, built context metadata, and trimming behavior consistent.

## Task 10 Learnings
- A dedicated `Task.Supervisor` is the clean OTP boundary for tool sandboxing: `Task.Supervisor.async_nolink/2` plus `Task.yield/2 || Task.shutdown/2` gives timeout enforcement without crashing the registry caller.
- Keeping tool names as strings in registry state avoids unsafe atom conversion while making provider tool specs and lookup keys line up with JSON function-calling payloads.
- Mox-based tool tests that execute in supervised task processes need global mode (or explicit allowances), otherwise expectations set in the test process are not visible inside sandboxed tool tasks.
