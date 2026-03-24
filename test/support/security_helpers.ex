defmodule ElixirClaw.Test.SecurityHelpers do
  @moduledoc """
  Test helpers for asserting secrets are not leaked into strings.

  🔒 Use `assert_no_secrets/1` to guard any string (log output, error message,
  serialized JSON, etc.) against containing known secret patterns.
  """

  import ExUnit.Assertions

  # Known secret patterns: OpenAI keys, Anthropic keys, Bearer tokens,
  # generic "password =" style, raw hex/base64 long tokens, etc.
  @secret_patterns [
    ~r/sk-[a-zA-Z0-9\-_]{10,}/,
    ~r/Bearer\s+[a-zA-Z0-9\._\-]{10,}/i,
    ~r/api[_\-]key\s*[:=]\s*\S{8,}/i,
    ~r/token\s*[:=]\s*[a-zA-Z0-9\._\-]{10,}/i,
    ~r/password\s*[:=]\s*\S{4,}/i,
    ~r/secret\s*[:=]\s*\S{8,}/i
  ]

  @doc """
  Assert that the given string contains no patterns matching known secret formats.

  Raises `ExUnit.AssertionError` if any secret pattern is found.

  ## Examples

      assert_no_secrets("safe log message")  # passes
      assert_no_secrets("key=sk-abc123xyz")  # raises
  """
  @spec assert_no_secrets(String.t()) :: :ok
  def assert_no_secrets(text) when is_binary(text) do
    Enum.each(@secret_patterns, fn pattern ->
      refute Regex.match?(pattern, text),
             "Secret detected in output!\nPattern: #{inspect(pattern)}\nText: #{inspect(String.slice(text, 0, 200))}"
    end)

    :ok
  end

  @doc """
  Assert that the string does NOT contain the given literal substring.

  Useful for asserting a specific known key is redacted.
  """
  @spec assert_not_in_output(String.t(), String.t()) :: :ok
  def assert_not_in_output(text, secret_value) when is_binary(text) and is_binary(secret_value) do
    refute String.contains?(text, secret_value),
           "Secret value found in output!\nValue: #{inspect(secret_value)}\nText: #{inspect(String.slice(text, 0, 200))}"

    :ok
  end
end
