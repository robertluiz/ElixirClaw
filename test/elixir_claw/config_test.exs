defmodule ElixirClaw.ConfigTest do
  use ExUnit.Case, async: true

  alias ElixirClaw.Config
  alias ElixirClaw.Config.Loader

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  test "load valid TOML config returns {:ok, %Config{}}" do
    path = Path.join(@fixtures_dir, "valid_config.toml")

    assert {:ok, %Config{} = config} = Loader.load(path)
    assert config.database_path == "test.db"
    assert config.max_context_tokens == 4096
    assert config.skill_token_budget == 1024
    assert config.rate_limit == 60

    assert [%{name: "openai", model: "gpt-4o-mini", api_key: "sk-test-key-12345"}] =
             config.providers

    assert [%{"type" => "cli"}] = config.channels
  end

  test "load missing required fields returns {:error, reasons}" do
    path = Path.join(@fixtures_dir, "invalid_config.toml")

    assert {:error, reasons} = Loader.load(path)
    assert Enum.any?(reasons, &String.contains?(&1, "providers"))
    assert Enum.any?(reasons, &String.contains?(&1, "channels"))
    assert Enum.any?(reasons, &String.contains?(&1, "database_path"))
  end

  test "secrets redacted in inspect output" do
    config = %Config{
      providers: [
        %Config.Provider{name: "openai", api_key: "sk-secret-value", model: "gpt-4o-mini"}
      ],
      channels: [
        %{"type" => "cli", "token" => "channel-secret"}
      ],
      database_path: "test.db",
      security: %{"password" => "super-secret", "nested" => %{"secret" => "keep-hidden"}}
    }

    inspected = inspect(config)

    assert inspected =~ "[REDACTED]"
    refute inspected =~ "sk-secret-value"
    refute inspected =~ "channel-secret"
    refute inspected =~ "super-secret"
    refute inspected =~ "keep-hidden"
  end

  test "env var interpolation resolves ${HOME}" do
    System.put_env("ELIXIR_CLAW_TEST_HOME", "C:/test-home")

    on_exit(fn -> System.delete_env("ELIXIR_CLAW_TEST_HOME") end)

    toml = """
    database_path = "${ELIXIR_CLAW_TEST_HOME}/claw.db"

    [[providers]]
    name = "openai"
    api_key = "sk-test-key-12345"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"
    """

    assert {:ok, %Config{} = config} = Loader.load_from_string(toml)
    assert config.database_path == "C:/test-home/claw.db"
  end

  test "placeholder API key rejected" do
    toml = """
    database_path = "test.db"

    [[providers]]
    name = "openai"
    api_key = "YOUR_KEY_HERE"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"
    """

    assert {:error, reasons} = Loader.load_from_string(toml)
    assert Enum.any?(reasons, &String.contains?(&1, "YOUR_KEY_HERE"))
  end

  test "load_from_string parses valid TOML" do
    toml = """
    database_path = "memory.db"
    max_context_tokens = 2048
    rate_limit = 30

    [[providers]]
    name = "openai"
    api_key = "sk-inline-test-key"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"
    """

    assert {:ok, %Config{} = config} = Loader.load_from_string(toml)
    assert config.database_path == "memory.db"
    assert config.max_context_tokens == 2048
    assert config.rate_limit == 30
    assert [%{name: "openai"}] = config.providers
  end

  test "security config loads tool policies and explicit approval defaults" do
    toml = """
    database_path = "memory.db"

    [[providers]]
    name = "openai"
    api_key = "sk-inline-test-key"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"

    [security]
    require_explicit_approval_for_privileged_tools = true

    [security.tool_policies]
    bash = "privileged"
    read_file = "standard"
    """

    assert {:ok, %Config{} = config} = Loader.load_from_string(toml)

    assert config.security == %{
             "require_explicit_approval_for_privileged_tools" => true,
             "tool_policies" => %{"bash" => "privileged", "read_file" => "standard"}
           }
  end

  test "security config defaults privileged approval requirement when omitted" do
    toml = """
    database_path = "memory.db"

    [[providers]]
    name = "openai"
    api_key = "sk-inline-test-key"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"
    """

    assert {:ok, %Config{} = config} = Loader.load_from_string(toml)

    assert config.security == %{
             "require_explicit_approval_for_privileged_tools" => true,
             "tool_policies" => %{}
           }
  end

  test "oauth providers can omit api_key when configured as codex or github_copilot" do
    toml = """
    database_path = "memory.db"

    [[providers]]
    name = "codex"
    model = "codex-mini"

    [[providers]]
    name = "github_copilot"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"
    """

    assert {:ok, %Config{} = config} = Loader.load_from_string(toml)
    assert Enum.map(config.providers, & &1.name) == ["codex", "github_copilot"]
  end

  test "loads specialized task agents for standard workflows" do
    toml = """
    database_path = "memory.db"

    [[providers]]
    name = "openai"
    api_key = "sk-inline-test-key"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"

    [[task_agents]]
    name = "release-manager"
    description = "Coordinates release preparation"
    system_prompt = "You are responsible for release readiness."
    tasks = ["Review changelog", "Verify release checklist"]
    """

    assert {:ok, %Config{} = config} = Loader.load_from_string(toml)

    assert [
             %{
               "name" => "release-manager",
               "description" => "Coordinates release preparation",
               "system_prompt" => "You are responsible for release readiness.",
               "tasks" => ["Review changelog", "Verify release checklist"]
             }
           ] = config.task_agents
  end

  test "rejects task agents missing required fields" do
    toml = """
    database_path = "memory.db"

    [[providers]]
    name = "openai"
    api_key = "sk-inline-test-key"
    model = "gpt-4o-mini"

    [[channels]]
    type = "cli"

    [[task_agents]]
    name = "release-manager"
    description = "Coordinates release preparation"
    tasks = ["Review changelog"]
    """

    assert {:error, reasons} = Loader.load_from_string(toml)

    assert Enum.any?(
             reasons,
             &String.contains?(&1, "task_agent release-manager system_prompt must be a non-empty string")
           )
  end
end
