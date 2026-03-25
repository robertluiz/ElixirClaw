defmodule ElixirClaw.Config do
  @moduledoc false

  @enforce_keys [:providers, :channels, :database_path]
  defstruct [
    :providers,
    :channels,
    :database_path,
    task_agents: [],
    skills_dir: nil,
    max_context_tokens: 4096,
    summarization_threshold: 0.6,
    skill_token_budget: 1024,
    rate_limit: 60,
    mcp_servers: [],
    security: %{}
  ]

  @sensitive_keys MapSet.new(["api_key", "token", "secret", "password"])

  defmodule Provider do
    @moduledoc false

    defstruct [
      :name,
      :api_key,
      :model,
      :base_url,
      extra: %{}
    ]

    def new(attrs) when is_map(attrs) do
      %__MODULE__{
        name: Map.get(attrs, "name") || Map.get(attrs, :name),
        api_key: Map.get(attrs, "api_key") || Map.get(attrs, :api_key),
        model: Map.get(attrs, "model") || Map.get(attrs, :model),
        base_url: Map.get(attrs, "base_url") || Map.get(attrs, :base_url),
        extra:
          attrs
          |> Map.drop([
            "name",
            "api_key",
            "model",
            "base_url",
            :name,
            :api_key,
            :model,
            :base_url
          ])
      }
    end

    def to_redacted_map(%__MODULE__{} = provider) do
      provider
      |> Map.from_struct()
      |> ElixirClaw.Config.redact_term()
    end
  end

  def to_redacted_map(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> redact_term()
  end

  def redact_term(term) when is_list(term), do: Enum.map(term, &redact_term/1)

  def redact_term(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> redact_term()
    |> then(&struct(module, &1))
  end

  def redact_term(term) when is_map(term) do
    Enum.into(term, %{}, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_term(value)}
      end
    end)
  end

  def redact_term(term), do: term

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))
  defp sensitive_key?(key) when is_binary(key), do: MapSet.member?(@sensitive_keys, key)
  defp sensitive_key?(_key), do: false
end

defimpl Inspect, for: ElixirClaw.Config do
  import Inspect.Algebra

  def inspect(config, opts) do
    concat(["#ElixirClaw.Config<", to_doc(ElixirClaw.Config.to_redacted_map(config), opts), ">"])
  end
end

defimpl Inspect, for: ElixirClaw.Config.Provider do
  import Inspect.Algebra

  def inspect(provider, opts) do
    concat([
      "#ElixirClaw.Config.Provider<",
      to_doc(ElixirClaw.Config.Provider.to_redacted_map(provider), opts),
      ">"
    ])
  end
end
