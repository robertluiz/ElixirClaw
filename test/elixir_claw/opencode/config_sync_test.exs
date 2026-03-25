defmodule ElixirClaw.OpenCode.ConfigSyncTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.OpenCode.ConfigSync

  @fixtures_dir Path.expand("../../fixtures/opencode", __DIR__)

  describe "sync_config/2" do
    test "imports sanitized MCP servers and deduplicated skill paths" do
      path = fixture_path("test_opencode.json")

      assert {:ok, %{mcp_servers: mcp_servers, skill_paths: skill_paths}} =
               ConfigSync.sync_config(path)

      assert [
               %{
                 name: "filesystem",
                 transport: "stdio",
                 command: "npx",
                 args: ["-y", "@anthropic/mcp-fs"]
               },
               %{
                 name: "webserver",
                 transport: "http",
                 url: "http://localhost:8080/mcp"
               }
             ] = Enum.sort_by(mcp_servers, & &1.name)

      assert skill_paths == ["~/.agents/skills", ".opencode/skills"]
    end

    test "returns config_not_found when file is missing" do
      assert {:error, :config_not_found} = ConfigSync.sync_config(fixture_path("missing.json"))
    end

    test "returns invalid_json for malformed JSONC" do
      assert {:error, :invalid_json} =
               ConfigSync.sync_config(fixture_path("invalid_opencode.json"))
    end
  end

  describe "import_mcp_servers/2" do
    test "filters providers, env, secret-like keys, and unsafe commands" do
      path = fixture_path("test_opencode_with_secrets.json")

      assert {:ok, servers} = ConfigSync.import_mcp_servers(path)

      assert [
               %{
                 name: "safe-http",
                 transport: "http",
                 url: "https://example.com/mcp"
               },
               %{
                 name: "safe-stdio",
                 transport: "stdio",
                 command: "node",
                 args: ["server.js"]
               }
             ] = Enum.sort_by(servers, & &1.name)

      refute Enum.any?(servers, &Map.has_key?(&1, :env))
      refute Enum.any?(servers, &Map.has_key?(&1, :api_key))
      refute Enum.any?(servers, &Map.has_key?(&1, :secret_token))
      refute Enum.any?(servers, &(&1.name == "unsafe-shell"))
    end
  end

  describe "import_skill_paths/2" do
    test "returns deduplicated skill paths only" do
      path = fixture_path("test_opencode_with_secrets.json")

      assert {:ok, ["~/.agents/skills", ".opencode/skills", "custom/skills"]} =
               ConfigSync.import_skill_paths(path)
    end
  end

  describe "diff_config/2" do
    test "supports JSONC comments while showing sanitized imports" do
      path = fixture_path("test_opencode_with_comments.json")

      assert {:ok, %{mcp_servers: servers, skill_paths: paths}} = ConfigSync.diff_config(path)

      assert [%{name: "commented", transport: "http", url: "http://localhost:5000/mcp"}] = servers
      assert paths == ["~/.agents/skills", ".opencode/skills"]
    end
  end

  defp fixture_path(name), do: Path.join(@fixtures_dir, name)
end
