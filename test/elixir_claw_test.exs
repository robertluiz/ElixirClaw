defmodule ElixirClawTest do
  use ExUnit.Case
  doctest ElixirClaw

  test "greets the world" do
    assert ElixirClaw.hello() == :world
  end
end
