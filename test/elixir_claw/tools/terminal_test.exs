defmodule ElixirClaw.Tools.TerminalTest do
  use ExUnit.Case, async: false

  alias ElixirClaw.Tools.{
    LaunchCodexTui,
    LaunchOpenCodeTui,
    ReadInteractiveTerminalOutput,
    RunTerminalCommand,
    SendInteractiveTerminalInput,
    StartInteractiveTerminalSession,
    StopInteractiveTerminalSession,
    TerminalSessionManager
  }

  alias ElixirClaw.Tools.Registry

  setup do
    unless Process.whereis(ElixirClaw.ToolSupervisor) do
      start_supervised!({Task.Supervisor, name: ElixirClaw.ToolSupervisor})
    end

    unless Process.whereis(ElixirClaw.TerminalSessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: ElixirClaw.TerminalSessionRegistry})
    end

    unless Process.whereis(ElixirClaw.TerminalSessionSupervisor) do
      start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, name: ElixirClaw.TerminalSessionSupervisor}
      )
    end

    unless Process.whereis(ElixirClaw.Tools.TerminalSessionManager) do
      start_supervised!({TerminalSessionManager, name: ElixirClaw.Tools.TerminalSessionManager})
    end

    start_supervised!({Registry, name: :terminal_test_registry})
    :ok
  end

  test "executes a local shell command and returns formatted output" do
    assert {:ok, output} = RunTerminalCommand.execute(%{"command" => success_command()}, %{})

    assert output =~ "$ "
    assert output =~ "exit_code=0"
    assert output =~ "hello-terminal"
  end

  test "returns invalid_cwd when cwd does not exist" do
    assert {:error, :invalid_cwd} =
             RunTerminalCommand.execute(
               %{"command" => success_command(), "cwd" => "C:/definitely/missing/dir"},
               %{}
             )
  end

  test "returns formatted output even when the command exits with failure" do
    assert {:ok, output} = RunTerminalCommand.execute(%{"command" => failure_command()}, %{})

    assert output =~ "$ "
    assert output =~ "exit_code="
  end

  test "is registered as a privileged tool that requires approval" do
    assert :ok = Registry.register(:terminal_test_registry, RunTerminalCommand)

    assert {:error, {:approval_required, "run_terminal_command"}} =
             Registry.execute(
               "run_terminal_command",
               %{"command" => success_command()},
               %{"metadata" => %{}},
               :terminal_test_registry
             )
  end

  test "executes through the registry when explicitly approved" do
    assert :ok = Registry.register(:terminal_test_registry, RunTerminalCommand)

    assert {:ok, output} =
             Registry.execute(
               "run_terminal_command",
               %{"command" => success_command()},
               %{"metadata" => %{"approved_tools" => ["run_terminal_command"]}},
               :terminal_test_registry
             )

    assert output =~ "exit_code=0"
    assert output =~ "hello-terminal"
  end

  test "launch_codex_tui is privileged and exposed through the registry" do
    assert :ok = Registry.register(:terminal_test_registry, LaunchCodexTui)

    assert {:error, {:approval_required, "launch_codex_tui"}} =
             Registry.execute(
               "launch_codex_tui",
               %{},
               %{"metadata" => %{}},
               :terminal_test_registry
             )
  end

  test "launch_codex_tui returns invalid_cwd when cwd does not exist" do
    assert {:error, :invalid_cwd} =
             LaunchCodexTui.execute(%{"cwd" => "C:/definitely/missing/dir"}, %{})
  end

  test "launch_opencode_tui is privileged and exposed through the registry" do
    assert :ok = Registry.register(:terminal_test_registry, LaunchOpenCodeTui)

    assert {:error, {:approval_required, "launch_opencode_tui"}} =
             Registry.execute(
               "launch_opencode_tui",
               %{},
               %{"metadata" => %{}},
               :terminal_test_registry
             )
  end

  test "bootstrap registers all terminal-oriented tools" do
    assert :ok = ElixirClaw.Tools.Bootstrap.register_builtin_tools(:terminal_test_registry)

    assert Enum.sort([
             "launch_codex_tui",
             "launch_opencode_tui",
             "read_interactive_terminal_output",
             "run_terminal_command",
             "send_interactive_terminal_input",
             "start_interactive_terminal_session",
             "stop_interactive_terminal_session"
           ]) -- Registry.list(:terminal_test_registry) == []
  end

  test "interactive terminal session lifecycle works through the manager" do
    assert {:ok, session_id} = TerminalSessionManager.start_session(%{})
    assert :ok = TerminalSessionManager.send_input(session_id, success_command())

    output = wait_for_output(session_id, "hello-terminal")
    assert output =~ "hello-terminal"

    assert :ok = TerminalSessionManager.stop_session(session_id)
    assert {:error, :session_not_found} = TerminalSessionManager.read_output(session_id)
  end

  test "interactive session accepts an initial prompt during startup" do
    assert {:ok, session_id} =
             TerminalSessionManager.start_session(%{"prompt" => success_command()})

    assert String.starts_with?(session_id, "term-")

    assert :ok = TerminalSessionManager.stop_session(session_id)
  end

  test "read_output can clear the buffered output" do
    assert {:ok, session_id} = TerminalSessionManager.start_session(%{})
    assert :ok = TerminalSessionManager.send_input(session_id, success_command())

    _output = wait_for_output(session_id, "hello-terminal")

    assert {:ok, cleared_output} = TerminalSessionManager.read_output(session_id, clear: true)
    assert cleared_output =~ "hello-terminal"
    assert {:ok, ""} = TerminalSessionManager.read_output(session_id)

    assert :ok = TerminalSessionManager.stop_session(session_id)
  end

  test "manager returns session_not_found for missing sessions" do
    assert {:error, :session_not_found} =
             TerminalSessionManager.send_input("term-missing", "echo hi")

    assert {:error, :session_not_found} = TerminalSessionManager.read_output("term-missing")
    assert {:error, :session_not_found} = TerminalSessionManager.stop_session("term-missing")
  end

  test "interactive terminal tools validate required params" do
    assert {:error, :invalid_cwd} = StartInteractiveTerminalSession.execute(%{"cwd" => 123}, %{})

    assert {:error, :invalid_params} =
             SendInteractiveTerminalInput.execute(%{"session_id" => "a"}, %{})

    assert {:error, :invalid_params} = ReadInteractiveTerminalOutput.execute(%{}, %{})
    assert {:error, :invalid_params} = StopInteractiveTerminalSession.execute(%{}, %{})
  end

  test "interactive terminal tools are privileged" do
    assert :ok = Registry.register(:terminal_test_registry, StartInteractiveTerminalSession)
    assert :ok = Registry.register(:terminal_test_registry, SendInteractiveTerminalInput)
    assert :ok = Registry.register(:terminal_test_registry, ReadInteractiveTerminalOutput)
    assert :ok = Registry.register(:terminal_test_registry, StopInteractiveTerminalSession)

    for tool_name <- [
          "start_interactive_terminal_session",
          "send_interactive_terminal_input",
          "read_interactive_terminal_output",
          "stop_interactive_terminal_session"
        ] do
      assert {:error, {:approval_required, ^tool_name}} =
               Registry.execute(tool_name, %{}, %{"metadata" => %{}}, :terminal_test_registry)
    end
  end

  defp success_command do
    if match?({:win32, _}, :os.type()) do
      "echo hello-terminal"
    else
      "printf hello-terminal"
    end
  end

  defp failure_command do
    if match?({:win32, _}, :os.type()) do
      "ver >nul && exit /b 7"
    else
      "sh -lc 'exit 7'"
    end
  end

  defp wait_for_output(session_id, expected, attempts \\ 20)

  defp wait_for_output(session_id, expected, attempts) when attempts > 0 do
    {:ok, output} = TerminalSessionManager.read_output(session_id)

    if String.contains?(output, expected) do
      output
    else
      Process.sleep(50)
      wait_for_output(session_id, expected, attempts - 1)
    end
  end

  defp wait_for_output(_session_id, expected, 0) do
    flunk("expected terminal output to contain #{inspect(expected)}")
  end
end
