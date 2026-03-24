Mox.defmock(ElixirClaw.MockProvider, for: ElixirClaw.Provider)
Mox.defmock(ElixirClaw.MockChannel, for: ElixirClaw.Channel)
Mox.defmock(ElixirClaw.MockTool, for: ElixirClaw.Tool)

if Code.ensure_loaded?(ElixirClaw.Channels.Discord.API) do
  Mox.defmock(ElixirClaw.MockDiscordAPI, for: ElixirClaw.Channels.Discord.API)
end

if Code.ensure_loaded?(ElixirClaw.Channels.Discord.SessionManager) do
  Mox.defmock(ElixirClaw.MockDiscordSessionManager, for: ElixirClaw.Channels.Discord.SessionManager)
end

if Code.ensure_loaded?(ElixirClaw.Channels.Discord.AgentLoop) do
  Mox.defmock(ElixirClaw.MockDiscordAgentLoop, for: ElixirClaw.Channels.Discord.AgentLoop)
end

Mox.defmock(ElixirClaw.MockHTTPClient, for: ElixirClaw.MCP.ToolWrapper.HTTPClientBehaviour)
Mox.defmock(ElixirClaw.MockStdioClient, for: ElixirClaw.MCP.ToolWrapper.StdioClientBehaviour)
