# ElixirClaw

ElixirClaw is an Elixir-based AI agent runtime that connects LLM providers (OpenAI, Anthropic, OpenRouter, Codex/Copilot) to communication channels (CLI, Telegram, Discord) via a configurable pipeline. It supports MCP (Model Context Protocol) tool servers, skill injection, session persistence with CozoDB, and rate limiting.

## Requirements

- Elixir 1.19+ / OTP 28+
- Node.js 20+ (used by the CozoDB bridge process)
- npm (used by the CozoDB bridge and GitHub Copilot Node bridge)

## Installation

```bash
# Clone the repository
git clone https://github.com/your-org/elixir_claw
cd elixir_claw

# Install dependencies
mix deps.get

# Compile
mix compile
```

Or bootstrap the whole workspace in one step:

```bash
mix setup
```

`mix setup` runs the initial installer, which:
- Copies `elixir_claw.example.toml` to `config/config.toml` when the config file is missing
- Installs Node dependencies with `npm install`
- Installs GitHub Copilot bridge dependencies with `npm install --prefix priv/copilot_bridge`
- Rebuilds the Cozo native bridge with `npm rebuild cozo-node`
- Installs Elixir dependencies with `mix deps.get`
- Compiles the project with `mix compile`
- Creates `.vscode/tasks.json` when the workspace does not already define tasks

## Configuration

Copy the example config and edit it:

```bash
cp elixir_claw.example.toml config/config.toml
```

Edit `config/config.toml` to configure providers, channels, and other settings.
Use environment variable interpolation for secrets: `api_key = "${OPENAI_API_KEY}"`.

You can also define specialized task agents for common workflows. These act like focused presets inspired by multi-agent toolkits such as oh-my-openagent, but are implemented here as session-scoped prompt profiles that fit the existing Elixir runtime.

### Skills directories

ElixirClaw now supports multiple skill directories.

At runtime, the project always considers the user-level skills folder:

- `~/.agents/skills`

You can also configure project-specific skill folders in `config/config.toml`:

```toml
[skills]
skills_dir = "./skills"
paths = ["./custom-skills"]
```

Resolution rules:
- `skills.skills_dir` is treated as the primary project skill directory when present.
- `skills.paths` can add extra skill directories.
- `~/.agents/skills` is added automatically as an additional fallback path.
- Paths are expanded and deduplicated before loading.

### Minimal configuration

```toml
[database]
database_path = "elixir_claw.cozo.db"

[providers.openai]
api_key = "${OPENAI_API_KEY}"
model = "gpt-4o-mini"

[channels.cli]
enabled = true

[[task_agents]]
name = "release-manager"
description = "Coordinate release readiness"
system_prompt = "You own release preparation, verification, and final readiness checks."
tasks = ["Review changelog", "Verify release checklist", "Summarize release risks"]
```

### Environment variables

| Variable | Description |
|---|---|
| `OPENAI_API_KEY` | OpenAI API key |
| `ANTHROPIC_API_KEY` | Anthropic Claude API key |
| `OPENROUTER_API_KEY` | OpenRouter API key |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `CODEX_CLIENT_ID` | OpenAI Codex OAuth client ID |
| `CODEX_CLIENT_SECRET` | OpenAI Codex OAuth client secret |
| `COPILOT_CLIENT_ID` | Optional override for the default GitHub Copilot OAuth client ID |

### Telegram setup

Compared with projects such as `nanobot`, the important operational rule here is: **ElixirClaw reads Telegram channel settings from `config/config.toml` at runtime** and only starts the channel when it is explicitly enabled and has a valid bot token.

#### 1. Create a bot with BotFather

- Open Telegram and talk to `@BotFather`
- Run `/newbot`
- Copy the bot token returned by BotFather

#### 2. Enable the Telegram channel in `config/config.toml`

```toml
[channels.telegram]
enabled = true
bot_token = "${TELEGRAM_BOT_TOKEN}"
allowed_chat_ids = []
```

Notes:
- `enabled = true` is required, otherwise the Telegram channel is not started.
- `bot_token` can be inline or interpolated from `TELEGRAM_BOT_TOKEN`.
- `allowed_chat_ids` is accepted by the runtime config shape, but the current Telegram channel implementation still routes based on private chat sessions rather than enforcing an allowlist.

#### 3. Export the token before starting the app

Unix/macOS:

```bash
export TELEGRAM_BOT_TOKEN="123456:ABCDEF..."
mix run --no-halt
```

Windows PowerShell:

```powershell
$env:TELEGRAM_BOT_TOKEN = "123456:ABCDEF..."
mix run --no-halt
```

Windows Command Prompt:

```bat
set TELEGRAM_BOT_TOKEN=123456:ABCDEF...
C:\ProgramData\chocolatey\lib\Elixir\tools\bin\mix.bat run --no-halt
```

#### 4. Start a private chat with your bot

The current Telegram implementation only accepts **private chats**. Group chats are rejected by design.

- Open your bot in Telegram
- Click **Start** or send `/start`
- Then send a normal message

The channel creates one session per Telegram private chat and routes subsequent messages to the same session until `/new` is used.

#### 5. Verify that Telegram actually connected

When startup is correct, the channel supervisor includes `telegram` in the startup log. If the token is missing or malformed, the app logs that Telegram startup was skipped.

Typical checks:
- `Starting ElixirClaw.Channels.Supervisor with channels: cli,telegram`
- sending `/start` to the bot returns the welcome message
- sending a normal text message creates a session for that chat and routes messages through the runtime

#### How this differs from nanobot

- `nanobot` has a dedicated Telegram onboarding flow and clearer operator docs out of the box
- `nanobot` uses long polling, while ElixirClaw currently exposes a channel process that consumes Telegram updates through the Telegex integration path in this codebase
- ElixirClaw now closes the biggest clarity gap by loading `config/config.toml` at runtime, so `enabled = true` plus `bot_token` in TOML actually affects startup

### GitHub Copilot Node bridge

`github_copilot` now runs through a local Node.js bridge backed by the official `@github/copilot-sdk` package.

Operational notes:
- the bridge lives in `priv/copilot_bridge`
- dependencies are installed with:

```bash
npm install --prefix priv/copilot_bridge
```

- the Elixir side forwards the token already stored by `mix copilot.login`
- the Node bridge uses that token with the official GitHub Copilot SDK over stdio

You still authenticate from Elixir with:

```bash
mix copilot.login
```

Then start the app normally:

```bash
mix run --no-halt
```

When a session uses `github_copilot`, the provider requests are routed through the Node bridge instead of the previous direct REST implementation.

### OAuth providers

Codex and GitHub Copilot can run without a static `api_key` in the provider config. Configure the provider entry and complete the login once:

```toml
[providers.codex]
model = "codex-mini"

[providers.github_copilot]
model = ["gpt-4o", "gpt-4.1", "claude-3-7-sonnet-20250219"]
```

Then authenticate from the CLI:

```bash
mix codex.login
mix copilot.login
```

`mix copilot.login` uses the standard public GitHub Copilot OAuth client ID by default. Set `COPILOT_CLIENT_ID` only if you need to override that default.

## Running

### Development (with Mix)

Start the project from an **interactive terminal** so the CLI worker can read from `stdin`:

```bash
mix run --no-halt
```

On Windows, if `mix` is not in `PATH`, use the Chocolatey-installed launcher directly:

```bat
C:\ProgramData\chocolatey\lib\Elixir\tools\bin\mix.bat run --no-halt
```

### CLI startup notes

- The local CLI channel is enabled by default by `ElixirClaw.Channels.Supervisor`.
- Run the command from Windows Terminal, PowerShell, `cmd.exe`, or another real interactive shell.
- In non-interactive environments (for example CI, detached runners, or shells without usable `stdin`), the CLI worker logs a warning and exits normally instead of crash-looping.
- When the CLI channel is active, the prompt appears as `elixir_claw>`.

### Current CLI runtime status

`mix run --no-halt` is the correct command to start the project through the CLI channel, but the current runtime wiring is important:

- the CLI process itself starts and reads from `stdin`
- local CLI commands such as `/help`, `/quit`, `/model`, `/session`, `/agent`, and `/approve` are parsed by `ElixirClaw.Channels.CLI`
- the CLI now auto-creates a local session, subscribes to its session topic, and dispatches free-text input through `ElixirClaw.Agent.Loop`

In other words, starting with `mix run --no-halt` now gives you a working local CLI conversation loop, while keeping the lightweight slash commands for session and task-agent management.

### Production (Elixir release)

Build a self-contained release (includes the Erlang runtime):

```bash
MIX_ENV=prod mix release
```

Run the release:

```bash
# Unix/macOS
_build/prod/rel/elixir_claw/bin/elixir_claw start

# Windows
_build\prod\rel\elixir_claw\bin\elixir_claw.bat start
```

## Windows Usage

ElixirClaw runs natively on Windows (no WSL required).

### Running tests on Windows

Use the full path to the Chocolatey-installed mix.bat:

```bat
C:\ProgramData\chocolatey\lib\Elixir\tools\bin\mix.bat test
```

Or add the Elixir bin directory to your `PATH` and run:

```bat
mix test
```

### Running ElixirClaw from the CLI on Windows

Use an interactive terminal session:

```bat
C:\ProgramData\chocolatey\lib\Elixir\tools\bin\mix.bat run --no-halt
```

If the shell is non-interactive, the application can still boot, but the local CLI prompt will be disabled gracefully.

### Suggested VS Code tasks

The workspace installer creates these tasks when `.vscode/tasks.json` is absent:

| Task | Command |
|---|---|
| Bootstrap workspace | `mix setup` |
| Compile project | `mix compile` |
| Run test suite | `mix test` |
| Run ElixirClaw | `mix run --no-halt` |
| Login Codex | `mix codex.login` |
| Login GitHub Copilot | `mix copilot.login` |

### ANSI color support

Windows 10 (build 1607+) and Windows 11 support ANSI escape codes in the terminal. If colors are not working, run the application from Windows Terminal or PowerShell 7+. The Command Prompt (`cmd.exe`) also works with ANSI enabled via:

```bat
REG ADD HKCU\Console /v VirtualTerminalLevel /t REG_DWORD /d 1
```

### MCP stdio tool servers

When configuring MCP stdio tool servers on Windows, the `command` field should use:
- Full paths: `command = ["C:\\path\\to\\tool.exe"]`
- `.cmd`/`.bat` scripts: automatically wrapped in `cmd.exe /c` by the client
- Scripts in PATH: resolved via `System.find_executable/1`

Example config for an MCP stdio server:

```toml
[[mcp_servers]]
name = "my-tool"
transport = "stdio"
command = ["node", "C:\\path\\to\\mcp-server\\index.js"]
```

### Release environment setup

Before running a release on Windows, configure environment variables in `rel/env.bat.eex` (copied to the release as `releases/<version>/env.bat`):

```bat
SET OPENAI_API_KEY=sk-...
SET ELIXIR_CLAW_DATABASE_PATH=C:\ProgramData\ElixirClaw\data.cozo.db
```

## CLI Commands

Once the CLI channel is configured and the application is running:

| Command | Description |
|---|---|
| `/help` | Show available commands |
| `/agents` | List available specialized task agents |
| `/agent` | Show the active specialized task agent for the current session |
| `/agent <name>` | Activate a specialized task agent for the current session |
| `/agent off` | Disable the specialized task agent for the current session |
| `/new` | Start a new session |
| `/model <name>` | Switch to a different model |
| `/session` | Show current session information |
| `/quit` or `/exit` | Exit the CLI |

### Specialized task agents

Specialized task agents are focused profiles for common engineering work such as feature delivery, bug fixing, test writing, refactoring, and code review.

- Built-in agents: `feature-builder`, `bug-fixer`, `test-writer`, `code-reviewer`, `refactoring-mentor`
- Runtime-configured agents: add one or more `[[task_agents]]` entries in TOML
- Session-scoped activation: use `/agent <name>` in the CLI to activate one for the current session

When a task agent is active, its mission and workflow checklist are injected into the system context before each user message, giving you a predictable workflow without creating extra OTP processes.

## Architecture

```
ElixirClaw.Application
├── ElixirClaw.Channels.Supervisor    # channel processes (CLI, Telegram, Discord)
├── ElixirClaw.Sessions.Manager       # session state + CozoDB persistence
├── ElixirClaw.MCP.Registry           # MCP tool server registry
└── ElixirClaw.Config.Loader          # TOML config + env var interpolation
```

## CozoDB storage mode

In the current implementation, CozoDB is file-backed in normal runtime and in-memory during tests:

- development/default config: local file path such as `elixir_claw_dev.cozo.db`
- test config: `:mem` engine for isolated ephemeral databases

So yes: **today the Cozo database is local-file based by default**, but the project also supports in-memory Cozo for tests.

## License

MIT
