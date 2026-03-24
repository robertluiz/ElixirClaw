defmodule ElixirClaw.Test.TokenHelpers do
  @moduledoc """
  Test helpers for asserting token economy constraints.

  💰 Use `assert_token_count/2` to verify token estimates and
  `assert_within_budget/2` to verify total usage stays within limits.
  """

  import ExUnit.Assertions

  alias ElixirClaw.Types.TokenUsage

  @doc """
  Assert that `actual_tokens` equals `expected_tokens`.

  Provides a descriptive error if counts differ.
  """
  @spec assert_token_count(non_neg_integer(), non_neg_integer()) :: :ok
  def assert_token_count(actual_tokens, expected_tokens)
      when is_integer(actual_tokens) and is_integer(expected_tokens) do
    assert actual_tokens == expected_tokens,
           "Token count mismatch: expected #{expected_tokens}, got #{actual_tokens}"

    :ok
  end

  @doc """
  Assert that `%TokenUsage{}` total is within `max_budget` tokens.

  Raises if the total exceeds the budget.
  """
  @spec assert_within_budget(TokenUsage.t(), non_neg_integer()) :: :ok
  def assert_within_budget(%TokenUsage{total: total}, max_budget)
      when is_integer(max_budget) do
    assert total <= max_budget,
           "Token budget exceeded: used #{total} tokens, budget is #{max_budget}"

    :ok
  end

  @doc """
  Assert that `%TokenUsage{}` total is NOT zero (provider actually returned usage).
  """
  @spec assert_tokens_tracked(TokenUsage.t()) :: :ok
  def assert_tokens_tracked(%TokenUsage{total: total}) do
    assert total > 0, "Expected non-zero token count but got 0 — is token tracking enabled?"
    :ok
  end
end
