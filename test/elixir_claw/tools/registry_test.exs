defmodule ElixirClaw.Tools.RegistryTest do
  use ExUnit.Case, async: false

  import Mox

  alias ElixirClaw.Tools.Registry

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()

    unless Process.whereis(ElixirClaw.ToolSupervisor) do
      start_supervised!({Task.Supervisor, name: ElixirClaw.ToolSupervisor})
    end

    start_supervised!({Registry, name: :test_registry})
    :ok
  end

  describe "register/2, list/1, and get/2" do
    test "registers a tool module, lists tool names, and fetches the module by name" do
      expect(ElixirClaw.MockTool, :name, fn -> "mock_tool" end)

      assert :ok = Registry.register(:test_registry, MockToolAdapter)
      assert Registry.list(:test_registry) == ["mock_tool"]
      assert {:ok, MockToolAdapter} = Registry.get("mock_tool", :test_registry)
      assert {:error, :not_found} = Registry.get("missing", :test_registry)
    end
  end

  describe "execute/4" do
    test "executes a registered tool under Task.Supervisor" do
      expect(ElixirClaw.MockTool, :name, fn -> "mock_tool" end)

      expect(ElixirClaw.MockTool, :parameters_schema, fn ->
        %{"type" => "object", "required" => ["query"]}
      end)

      expect(ElixirClaw.MockTool, :timeout_ms, fn -> 100 end)
      expect(ElixirClaw.MockTool, :max_output_bytes, fn -> 65_536 end)

      expect(ElixirClaw.MockTool, :execute, fn %{"query" => "otp"}, %{"session_id" => "s-1"} ->
        {:ok, "result:otp"}
      end)

      assert :ok = Registry.register(:test_registry, MockToolAdapter)

      assert {:ok, "result:otp"} =
               Registry.execute(
                 "mock_tool",
                 %{"query" => "otp"},
                 %{"session_id" => "s-1"},
                 :test_registry
               )
    end

    test "returns invalid_params when required params are missing" do
      expect(ElixirClaw.MockTool, :name, fn -> "mock_tool" end)

      expect(ElixirClaw.MockTool, :parameters_schema, fn ->
        %{"type" => "object", "required" => ["query"]}
      end)

      assert :ok = Registry.register(:test_registry, MockToolAdapter)

      assert {:error, :invalid_params} = Registry.execute("mock_tool", %{}, %{}, :test_registry)
    end

    test "returns timeout when tool execution exceeds timeout_ms" do
      expect(ElixirClaw.MockTool, :name, fn -> "slow_tool" end)

      expect(ElixirClaw.MockTool, :parameters_schema, fn ->
        %{"type" => "object", "required" => []}
      end)

      expect(ElixirClaw.MockTool, :timeout_ms, fn -> 10 end)
      expect(ElixirClaw.MockTool, :max_output_bytes, fn -> 65_536 end)

      expect(ElixirClaw.MockTool, :execute, fn %{}, %{} ->
        Process.sleep(50)
        {:ok, "late"}
      end)

      assert :ok = Registry.register(:test_registry, SlowToolAdapter)
      assert {:error, :timeout} = Registry.execute("slow_tool", %{}, %{}, :test_registry)
    end

    test "truncates output larger than max_output_bytes and appends a marker" do
      expect(ElixirClaw.MockTool, :name, fn -> "large_output_tool" end)

      expect(ElixirClaw.MockTool, :parameters_schema, fn ->
        %{"type" => "object", "required" => []}
      end)

      expect(ElixirClaw.MockTool, :timeout_ms, fn -> 100 end)
      expect(ElixirClaw.MockTool, :max_output_bytes, fn -> 20 end)

      expect(ElixirClaw.MockTool, :execute, fn %{}, %{} ->
        {:ok, String.duplicate("a", 25)}
      end)

      assert :ok = Registry.register(:test_registry, LargeOutputToolAdapter)

      assert {:ok, output} = Registry.execute("large_output_tool", %{}, %{}, :test_registry)
      assert output == String.duplicate("a", 20) <> "[OUTPUT TRUNCATED at 64KB]"
    end

    test "catches tool exceptions and returns an error tuple" do
      expect(ElixirClaw.MockTool, :name, fn -> "crashy_tool" end)

      expect(ElixirClaw.MockTool, :parameters_schema, fn ->
        %{"type" => "object", "required" => []}
      end)

      expect(ElixirClaw.MockTool, :timeout_ms, fn -> 100 end)
      expect(ElixirClaw.MockTool, :max_output_bytes, fn -> 65_536 end)

      expect(ElixirClaw.MockTool, :execute, fn %{}, %{} ->
        raise "boom"
      end)

      assert :ok = Registry.register(:test_registry, CrashyToolAdapter)
      assert {:error, reason} = Registry.execute("crashy_tool", %{}, %{}, :test_registry)
      refute reason == :timeout
    end
  end

  describe "to_provider_format/1" do
    test "returns an empty list when no tools are registered" do
      assert Registry.to_provider_format(:test_registry) == []
    end

    test "converts registered tools to OpenAI function calling format" do
      schema = %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }

      expect(ElixirClaw.MockTool, :name, 2, fn -> "mock_tool" end)
      expect(ElixirClaw.MockTool, :description, fn -> "Searches mock data" end)
      expect(ElixirClaw.MockTool, :parameters_schema, fn -> schema end)

      assert :ok = Registry.register(:test_registry, MockToolAdapter)

      assert Registry.to_provider_format(:test_registry) == [
               %{
                 type: "function",
                 function: %{
                   name: "mock_tool",
                   description: "Searches mock data",
                   parameters: schema
                 }
               }
             ]
    end
  end
end

defmodule MockToolAdapter do
  @behaviour ElixirClaw.Tool

  defdelegate name(), to: ElixirClaw.MockTool
  defdelegate description(), to: ElixirClaw.MockTool
  defdelegate parameters_schema(), to: ElixirClaw.MockTool
  defdelegate execute(params, context), to: ElixirClaw.MockTool
  defdelegate max_output_bytes(), to: ElixirClaw.MockTool
  defdelegate timeout_ms(), to: ElixirClaw.MockTool
end

defmodule SlowToolAdapter do
  @behaviour ElixirClaw.Tool

  defdelegate description(), to: MockToolAdapter
  defdelegate parameters_schema(), to: MockToolAdapter
  defdelegate execute(params, context), to: MockToolAdapter
  defdelegate max_output_bytes(), to: MockToolAdapter
  defdelegate timeout_ms(), to: MockToolAdapter
  defdelegate name(), to: ElixirClaw.MockTool
end

defmodule LargeOutputToolAdapter do
  @behaviour ElixirClaw.Tool

  defdelegate description(), to: MockToolAdapter
  defdelegate parameters_schema(), to: MockToolAdapter
  defdelegate execute(params, context), to: MockToolAdapter
  defdelegate max_output_bytes(), to: MockToolAdapter
  defdelegate timeout_ms(), to: MockToolAdapter
  defdelegate name(), to: ElixirClaw.MockTool
end

defmodule CrashyToolAdapter do
  @behaviour ElixirClaw.Tool

  defdelegate description(), to: MockToolAdapter
  defdelegate parameters_schema(), to: MockToolAdapter
  defdelegate execute(params, context), to: MockToolAdapter
  defdelegate max_output_bytes(), to: MockToolAdapter
  defdelegate timeout_ms(), to: MockToolAdapter
  defdelegate name(), to: ElixirClaw.MockTool
end
