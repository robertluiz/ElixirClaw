defmodule ElixirClaw.Tools.TerminalHelpers do
  @moduledoc false

  def validate_cwd(nil), do: {:ok, nil}

  def validate_cwd(cwd) when is_binary(cwd) do
    trimmed = String.trim(cwd)

    cond do
      trimmed == "" -> {:ok, nil}
      File.dir?(trimmed) -> {:ok, trimmed}
      true -> {:error, :invalid_cwd}
    end
  end

  def validate_cwd(_cwd), do: {:error, :invalid_cwd}

  def launcher_schema(prompt_description, model_description, include_port? \\ false) do
    properties = %{
      "prompt" => %{"type" => "string", "description" => prompt_description},
      "model" => %{"type" => "string", "description" => model_description},
      "cwd" => %{
        "type" => "string",
        "description" => "Optional working directory used when launching the TUI."
      }
    }

    properties =
      if include_port? do
        Map.put(properties, "port", %{
          "type" => "integer",
          "description" => "Optional fixed port when the CLI supports it."
        })
      else
        properties
      end

    %{"type" => "object", "properties" => properties, "required" => []}
  end

  def maybe_append_flag(args, _flag, nil), do: args
  def maybe_append_flag(args, _flag, ""), do: args
  def maybe_append_flag(args, flag, value), do: args ++ [flag, to_string(value)]

  def maybe_append_prompt(args, nil), do: args
  def maybe_append_prompt(args, ""), do: args
  def maybe_append_prompt(args, prompt), do: args ++ [prompt]

  def prepend_args(args, prefix), do: prefix ++ args

  def launch_tui(executable, args, cwd, label, env \\ []) do
    with {:ok, resolved_cwd} <- validate_cwd(cwd),
         {:ok, executable_path} <- resolve_executable(executable),
         {:ok, launcher_command} <-
           terminal_launcher_command(executable_path, args, resolved_cwd, env),
         {:ok, _output} <- run_launcher(launcher_command) do
      {:ok, format_launcher_result(label, executable_path, args, resolved_cwd)}
    end
  end

  defp resolve_executable(executable) do
    case System.find_executable(executable) do
      nil -> {:error, :command_not_found}
      path -> {:ok, path}
    end
  end

  defp terminal_launcher_command(executable, args, cwd, env) do
    case :os.type() do
      {:win32, _} ->
        {:ok,
         {System.get_env("COMSPEC") || "cmd",
          ["/d", "/s", "/c", build_windows_start_command(executable, args, cwd, env)]}}

      _other ->
        {:error, :unsupported_platform}
    end
  end

  defp run_launcher({shell, shell_args}) do
    case System.cmd(shell, shell_args, stderr_to_stdout: true) do
      {_output, 0} -> {:ok, :launched}
      {output, _status} -> {:error, output}
    end
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end

  defp format_launcher_result(label, executable_path, args, cwd) do
    [
      "Launched #{label}.",
      "executable=#{executable_path}",
      if(cwd, do: "cwd=#{cwd}", else: nil),
      "args=#{Enum.join(args, " ")}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp build_windows_start_command(executable, args, cwd, env) do
    env_prefix =
      env
      |> Enum.map(fn {key, value} -> "set \"#{key}=#{value}\"" end)
      |> Enum.join(" && ")

    cd_prefix =
      case cwd do
        nil -> nil
        path -> "cd /d \"#{path}\""
      end

    command = Enum.join([quote_windows(executable) | Enum.map(args, &quote_windows/1)], " ")

    [env_prefix, cd_prefix, "start \"\" #{command}"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" && ")
  end

  defp quote_windows(value) do
    escaped = String.replace(to_string(value), "\"", "\\\"")
    "\"#{escaped}\""
  end
end

defmodule ElixirClaw.Tools.RunTerminalCommand do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  @default_timeout_ms 60_000
  @default_max_output_bytes 65_536

  alias ElixirClaw.Tools.TerminalHelpers

  @impl true
  def name, do: "run_terminal_command"

  @impl true
  def description do
    "Run a shell command on the local machine terminal and return the combined command output. Use this for local inspection, diagnostics, or scripted command execution."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "Shell command to execute on the local machine."
        },
        "cwd" => %{
          "type" => "string",
          "description" => "Optional working directory for the command."
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = params, _context) when is_binary(command) do
    with :ok <- validate_command(command),
         {:ok, cwd} <- TerminalHelpers.validate_cwd(Map.get(params, "cwd")) do
      run_command(command, cwd)
    end
  end

  def execute(_params, _context), do: {:error, :invalid_params}

  @impl true
  def risk_tier, do: :privileged

  @impl true
  def group, do: "Terminal"

  @impl true
  def max_output_bytes, do: @default_max_output_bytes

  @impl true
  def timeout_ms, do: @default_timeout_ms

  defp validate_command(command) do
    if String.trim(command) == "" do
      {:error, :invalid_params}
    else
      :ok
    end
  end

  defp shell_command(command) do
    if match?({:win32, _}, :os.type()) do
      {System.get_env("COMSPEC") || "cmd", ["/d", "/s", "/c", command]}
    else
      {"/bin/sh", ["-lc", command]}
    end
  end

  defp command_opts(cwd) do
    []
    |> Keyword.put(:stderr_to_stdout, true)
    |> maybe_put_cwd(cwd)
  end

  defp maybe_put_cwd(opts, nil), do: opts
  defp maybe_put_cwd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  defp format_result(command, output, exit_code, cwd) do
    [
      "$ #{command}",
      format_cwd(cwd),
      "exit_code=#{exit_code}",
      "",
      if(output == "", do: "[no output]", else: output)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp format_cwd(nil), do: nil
  defp format_cwd(cwd), do: "cwd=#{cwd}"

  defp run_command(command, cwd) do
    {shell, shell_args} = shell_command(command)
    {output, exit_code} = System.cmd(shell, shell_args, command_opts(cwd))
    {:ok, format_result(command, output, exit_code, cwd)}
  rescue
    error in ErlangError ->
      {:ok, format_result(command, Exception.message(error), exit_code_from_error(error), cwd)}
  end

  defp exit_code_from_error(%ErlangError{original: :enoent}), do: 127
  defp exit_code_from_error(_error), do: 1
end

defmodule ElixirClaw.Tools.LaunchCodexTui do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  @default_timeout_ms 10_000
  @default_max_output_bytes 8_192

  alias ElixirClaw.Tools.TerminalHelpers

  @impl true
  def name, do: "launch_codex_tui"

  @impl true
  def description do
    "Launch the Codex interactive TUI in a real terminal window. Use this when the user wants the Codex full-screen interactive interface instead of a one-shot command."
  end

  @impl true
  def parameters_schema do
    TerminalHelpers.launcher_schema(
      "Optional initial prompt passed to Codex.",
      "Optional model override for the Codex TUI."
    )
  end

  @impl true
  def execute(params, _context) do
    args =
      []
      |> TerminalHelpers.maybe_append_prompt(Map.get(params, "prompt"))
      |> TerminalHelpers.maybe_append_flag("-m", Map.get(params, "model"))
      |> TerminalHelpers.prepend_args(["--no-alt-screen"])

    TerminalHelpers.launch_tui("codex", args, Map.get(params, "cwd"), "Codex TUI")
  end

  @impl true
  def risk_tier, do: :privileged

  @impl true
  def group, do: "Terminal"

  @impl true
  def max_output_bytes, do: @default_max_output_bytes

  @impl true
  def timeout_ms, do: @default_timeout_ms
end

defmodule ElixirClaw.Tools.LaunchOpenCodeTui do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  @default_timeout_ms 10_000
  @default_max_output_bytes 8_192

  alias ElixirClaw.Tools.TerminalHelpers

  @impl true
  def name, do: "launch_opencode_tui"

  @impl true
  def description do
    "Launch the OpenCode interactive TUI in a real terminal window. Use this when the user wants the OpenCode full-screen interactive interface instead of a one-shot command."
  end

  @impl true
  def parameters_schema do
    TerminalHelpers.launcher_schema(
      "Optional initial prompt passed to OpenCode.",
      "Optional model override for the OpenCode TUI.",
      true
    )
  end

  @impl true
  def execute(params, _context) do
    args =
      []
      |> TerminalHelpers.maybe_append_flag("--prompt", Map.get(params, "prompt"))
      |> TerminalHelpers.maybe_append_flag("--model", Map.get(params, "model"))
      |> TerminalHelpers.maybe_append_flag("--port", Map.get(params, "port"))

    env = [
      {"OPENCODE_DISABLE_AUTOUPDATE", "true"},
      {"OPENCODE_DISABLE_TERMINAL_TITLE", "true"}
    ]

    TerminalHelpers.launch_tui(
      "opencode",
      args,
      Map.get(params, "cwd"),
      "OpenCode TUI",
      env
    )
  end

  @impl true
  def risk_tier, do: :privileged

  @impl true
  def group, do: "Terminal"

  @impl true
  def max_output_bytes, do: @default_max_output_bytes

  @impl true
  def timeout_ms, do: @default_timeout_ms
end

defmodule ElixirClaw.Tools.StartInteractiveTerminalSession do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.Tools.TerminalSessionManager

  @impl true
  def name, do: "start_interactive_terminal_session"

  @impl true
  def description do
    "Start a persistent interactive terminal session that can receive follow-up input and return buffered output across multiple tool calls."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "cwd" => %{
          "type" => "string",
          "description" => "Optional working directory for the session shell."
        },
        "prompt" => %{
          "type" => "string",
          "description" => "Optional initial command sent immediately after the shell starts."
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(params, _context) do
    with {:ok, session_id} <- TerminalSessionManager.start_session(params) do
      {:ok, "Started interactive terminal session.\nsession_id=#{session_id}"}
    end
  end

  @impl true
  def risk_tier, do: :privileged

  @impl true
  def group, do: "Terminal"
  @impl true
  def max_output_bytes, do: 4_096
  @impl true
  def timeout_ms, do: 10_000
end

defmodule ElixirClaw.Tools.SendInteractiveTerminalInput do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.Tools.TerminalSessionManager

  @impl true
  def name, do: "send_interactive_terminal_input"

  @impl true
  def description do
    "Send a line of input to an existing interactive terminal session."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Interactive terminal session id."},
        "input" => %{
          "type" => "string",
          "description" => "Input sent to the running terminal session."
        }
      },
      "required" => ["session_id", "input"]
    }
  end

  @impl true
  def execute(%{"session_id" => session_id, "input" => input}, _context) do
    case TerminalSessionManager.send_input(session_id, input) do
      :ok -> {:ok, "Sent input to terminal session.\nsession_id=#{session_id}"}
      {:error, _reason} = error -> error
    end
  end

  def execute(_params, _context), do: {:error, :invalid_params}

  @impl true
  def risk_tier, do: :privileged

  @impl true
  def group, do: "Terminal"
  @impl true
  def max_output_bytes, do: 2_048
  @impl true
  def timeout_ms, do: 10_000
end

defmodule ElixirClaw.Tools.ReadInteractiveTerminalOutput do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.Tools.TerminalSessionManager

  @impl true
  def name, do: "read_interactive_terminal_output"

  @impl true
  def description do
    "Read buffered output from an interactive terminal session, optionally clearing the buffer after reading."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Interactive terminal session id."},
        "clear" => %{
          "type" => "boolean",
          "description" => "Clear the output buffer after reading."
        }
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def execute(%{"session_id" => session_id} = params, _context) do
    with {:ok, output} <-
           TerminalSessionManager.read_output(session_id, clear: Map.get(params, "clear", false)) do
      {:ok,
       [
         "session_id=#{session_id}",
         "",
         if(output == "", do: "[no buffered output]", else: output)
       ]
       |> Enum.join("\n")
       |> String.trim_trailing()}
    end
  end

  def execute(_params, _context), do: {:error, :invalid_params}

  @impl true
  def risk_tier, do: :privileged

  @impl true
  def group, do: "Terminal"
  @impl true
  def max_output_bytes, do: 65_536
  @impl true
  def timeout_ms, do: 10_000
end

defmodule ElixirClaw.Tools.StopInteractiveTerminalSession do
  @moduledoc false

  @behaviour ElixirClaw.Tool

  alias ElixirClaw.Tools.TerminalSessionManager

  @impl true
  def name, do: "stop_interactive_terminal_session"

  @impl true
  def description do
    "Stop and dispose of an interactive terminal session."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Interactive terminal session id."}
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def execute(%{"session_id" => session_id}, _context) do
    case TerminalSessionManager.stop_session(session_id) do
      :ok -> {:ok, "Stopped interactive terminal session.\nsession_id=#{session_id}"}
      {:error, _reason} = error -> error
    end
  end

  def execute(_params, _context), do: {:error, :invalid_params}

  @impl true
  def risk_tier, do: :privileged

  @impl true
  def group, do: "Terminal"
  @impl true
  def max_output_bytes, do: 2_048
  @impl true
  def timeout_ms, do: 10_000
end
