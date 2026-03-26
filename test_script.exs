defmodule Test do
  def run do
    provider = "openrouter"
    model = "anthropic/claude-3.7-sonnet"
    
    cond do
      provider == "anthropic" and String.contains?(model, "claude-3-7") ->
        IO.puts("Anthropic match")
      provider in ["openai", "openrouter"] and String.starts_with?(model, ["o1", "o3"]) ->
        IO.puts("OpenAI match")
      true ->
        IO.puts("No match")
    end
  end
end
Test.run()
