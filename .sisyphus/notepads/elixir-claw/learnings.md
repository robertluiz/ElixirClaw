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

## Task 11 Learnings
- `ElixirClaw.Agent.Loop` works best as a plain synchronous module: `Session.Worker` already owns per-session process state, so the orchestration pipeline can stay functional and side-effectful without introducing another mailbox hop.
- `Session.Manager.get_session/1` returns session metadata/state but not persisted history updates, so the orchestration layer must hydrate conversation history from `messages` in Ecto before calling `ContextBuilder.build_context/3`.
- The default orchestration path needs a supervised `ElixirClaw.Tools.Registry`; otherwise `ToolRegistry.to_provider_format/0` and `execute/3` have no default server to talk to outside isolated tests.
- In this project, `function_exported?/3` on Mox-generated mocks can be flaky unless the mock modules are eagerly loaded; `Code.ensure_loaded?/1` at app startup keeps the existing behaviour tests stable.

## Task 12 Learnings
- There was no Context7 entry for `req_llm`, so the practical fallback was Req docs plus source-level librarian notes; `Req.post(..., into: :self)` is enough to expose a lazy `Req.Response.Async` enumerable for SSE parsing.
- Bypass chunked SSE tests are stable when each `Plug.Conn.chunk/2` result is matched and the handler returns the final `conn`, not `{:ok, conn}`.
- Keeping OpenAI-compatible parsing in a small `OpenAICompat` module makes `tool_calls`, token usage, and message formatting reusable for future OpenRouter/Copilot BYOK adapters without sharing HTTP concerns.

## Task 13 Learnings
- Anthropic Messages API needs `system` lifted to a top-level field, `x-api-key` auth, and `anthropic-version` headers; replayed tool outputs must be sent back as a `user` message containing `tool_result` blocks instead of a `tool` role.
- Anthropic token usage is provider-specific (`input_tokens` / `output_tokens`), so reuse of OpenAI helpers should stop at generic message/tool formatting ideas rather than usage parsing.
- Anthropic SSE handling is easiest with event-aware state: capture `message_start` input tokens, emit text on `content_block_delta` text deltas, accumulate streamed tool JSON across `input_json_delta` chunks, and emit the final usage/finish-reason chunk from `message_delta`.

## Task 14 Learnings
- OpenRouter can stay nearly identical to the OpenAI provider by only swapping the endpoint, adding `HTTP-Referer`/`X-Title` headers, mapping `429` to `:rate_limited`, and optionally forwarding configured `transforms`.
- When OpenRouter config may be a root endpoint or a version root, normalizing `base_url` by appending `/chat/completions` only when needed keeps both default and Bypass test URLs working.
- The repo's full `mix test` is currently blocked by pre-existing `ElixirClaw.Providers.AnthropicTest` failures because `ElixirClaw.Providers.Anthropic` is not implemented yet; OpenRouter-targeted tests and compile are green.

## Task 16 Learnings
- A small OAuth helper module fits the existing provider style well when it merges module config with per-call opts, uses explicit response normalization, and injects the HTTP requester for security-focused tests without logging secrets.
- PKCE generation is simplest with 48 random bytes encoded via `Base.url_encode64/2`, which yields a 64-character verifier and a clean RFC 7636 `S256` challenge.
- The in-memory token manager can keep the required three-key state shape and still support lazy auto-refresh by reading OAuth client config from application env instead of persisting any refresh metadata elsewhere.

## Task 15 Learnings
- Copilot BYOK fits the same thin-wrapper pattern as other OpenAI-compatible providers: keep HTTP wiring local, and reuse `OpenAICompat` for message formatting, tool call parsing, and OpenAI-style token usage parsing.
- Treating `base_url` as either a version root or a full chat-completions endpoint avoids hardcoding a single vendor URL while keeping Bypass tests easy to write.
- Logging only an insecure-HTTP warning for `http://` endpoints satisfies security visibility without leaking API keys or request payloads.

## Task 17 Learnings
- Codex Responses API needs its own request conversion layer: system messages become `instructions`, provider tool specs must be flattened from OpenAI-style `%{type: "function", function: ...}` into `%{"type" => "function", "name" => ..., "parameters" => ...}`, and conversation history must be reshaped into `input` items.
- Preserving both Codex `call_id` and output-item `id` inside a normalized tool-call identifier like `call_id|item_id` keeps tool-result roundtrips possible: later `tool` messages can recover the upstream `call_id` without inventing new state.
- Named SSE parsing fits the Anthropic-style event parser well: accumulate `response.output_item.added/done` function-call state, emit text only from `response.content_part.delta`, and attach final `%TokenUsage{}` from `response.completed`.

## Task 18 Learnings
- A simple SKILL.md parser can stay dependency-free by splitting on lines, requiring opening/closing `---` delimiters, and only supporting the frontmatter shapes the project actually needs.
- Keeping frontmatter keys as strings and mapping only known fields into `%ElixirClaw.Skills.Skill{}` avoids unsafe atom creation while still giving typed defaults for optional metadata.
- Returning `{:error, {path, reason}}` from directory loads preserves per-file failures without aborting the whole scan, which makes malformed skill fixtures easy to surface in tests.

## Task 20 Learnings (MCP HTTP Client)
- `Hermes.Client.Supervisor` can be used directly without `use Hermes.Client`; the practical wrapper pattern is to start the Hermes supervisor, keep unique client/transport names, and call `Hermes.Client.Base` functions from the wrapper.
- For multiple MCP HTTP clients in one BEAM, `{:global, {module, unique_id, role}}` names are the simplest safe way to avoid dynamic atom creation while still satisfying Hermes' named-process requirements.
- Hermes' own request timeout can kill the internal client process, so the wrapper should use a slightly larger inner Hermes timeout and enforce the public timeout externally with `Task.yield/2 || Task.shutdown/2`.

## Task 26 Learnings
- Conversation consolidation can stay small and testable as a synchronous module when it scopes itself to Ecto reads/writes plus a single provider callback; a transaction is enough to swap old history for one summary message safely.
- For this repo's SQLite in-memory tests, `setup_all` with shared sandbox ownership plus explicit table creation keeps new Ecto-backed test files deterministic without introducing a separate DataCase helper.
- Ordering by `inserted_at` alone is not stable for same-timestamp fixture rows; adding `id` as a tiebreaker or sorting assertions avoids flaky message-history tests.

## Task 19 Learnings
- Skill trigger matching can stay safe by lowercasing the incoming message, treating plain-string triggers as substring checks, and mapping regex flags manually for `:re` instead of converting user-controlled strings into atoms.
- Budget-aware skill composition is easiest when it resolves dependency bundles first, includes dependencies before dependents in the composed content, and skips the whole bundle when the remaining budget cannot accommodate all required skills.

## Task 24 Learnings
- A Telegram channel GenServer can stay testable by wrapping `Telegex.send_message/2` behind a small behaviour and swapping in a Mox mock through channel config instead of touching the real network.
- Channel processes that create sessions in tests need shared or allowed SQL sandbox access; setting the test connection to `{:shared, self()}` keeps `Session.Manager.start_session/1` usable from inside the channel GenServer.

## Task 21 Learnings
- Port-based MCP tests stay hermetic if the client injects `:port_open_fn`, `:send_fn`, and `:port_close_fn`; then raw `{port, {:data, {:eol, line}}}` and `{port, {:exit_status, status}}` tuples can be simulated without launching a real child process.
- Resolving trusted commands before `GenServer.start_link/3` keeps `start_link/1` failures clean (`{:error, :command_not_found}`) while still allowing Windows-safe `{:spawn_executable, path}` usage and optional `cmd.exe /c` wrapping for `.cmd`/`.bat` scripts.
- Tracking pending JSON-RPC calls as `id => {from, timer_ref, request_type}` makes timeout cleanup, response correlation, and bulk failure on port exit straightforward without mixing protocol parsing into the public API layer.

## Task 22 Learnings
- MCP tool registration fits the existing registry cleanly if the registry stores either classic tool modules or `%ElixirClaw.MCP.ToolWrapper{}` structs and dispatches metadata/execution through small helper functions instead of forcing dynamic module generation.
- For Mox-based MCP wrapper tests, injecting the HTTP/stdio client modules through application env keeps the wrapper production-safe while letting supervised `ToolRegistry.execute/4` tasks hit global Mox expectations without changing the public wrapper API.
- `register_mcp_tools/4` should normalize both tagged (`{:ok, tools}`) and plain-list `list_tools/1` client results, because the current MCP clients and inherited task notes disagree on return shape.
