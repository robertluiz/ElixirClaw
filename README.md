# ElixirClaw

ElixirClaw is an Elixir-based AI agent runtime that connects LLM providers (OpenAI, Anthropic, OpenRouter, Codex/Copilot) to communication channels (CLI, Telegram, Discord) via a configurable pipeline. It supports MCP (Model Context Protocol) tool servers, skill injection, session persistence with CozoDB, and rate limiting.

## Requirements

- Elixir 1.19+ / OTP 28+
- Node.js 20+ (used by the CozoDB bridge process)

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

## Configuration

Copy the example config and edit it:

```bash
cp elixir_claw.example.toml config/config.toml
```

Edit `config/config.toml` to configure providers, channels, and other settings.
Use environment variable interpolation for secrets: `api_key = "${OPENAI_API_KEY}"`.

You can also define specialized task agents for common workflows. These act like focused presets inspired by multi-agent toolkits such as oh-my-openagent, but are implemented here as session-scoped prompt profiles that fit the existing Elixir runtime.

### Required configuration

```toml
[database]
database_path = "elixir_claw.cozo.db"

[[providers]]
name = "openai"
type = "openai"
api_key = "${OPENAI_API_KEY}"
models = ["gpt-4o-mini"]

[[channels]]
type = "cli"

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
| `COPILOT_CLIENT_ID` | GitHub OAuth app client ID for Copilot |
| `COPILOT_CLIENT_SECRET` | GitHub OAuth app client secret for Copilot |

### OAuth providers

Codex and GitHub Copilot can run without a static `api_key` in the provider config. Configure the provider entry and complete the login once:

```toml
[[providers]]
name = "codex"
model = "codex-mini"

[[providers]]
name = "github_copilot"
model = "gpt-4o-mini"
```

Then authenticate from the CLI:

```bash
mix codex.login
mix copilot.login
```

## Running

### Development (with Mix)

```bash
mix run --no-halt
```

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
