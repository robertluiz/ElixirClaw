defmodule ElixirClaw.Config.StartupManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ElixirClaw.Config.StartupManager

  describe "interpolate_env_vars/1" do
    test "interpolates only allowed secret env vars and leaves restricted vars literal" do
      System.put_env("OPENAI_API_KEY", "sk-test-openai")
      System.put_env("HOME", "C:/sensitive-home")

      on_exit(fn ->
        System.delete_env("OPENAI_API_KEY")
        System.delete_env("HOME")
      end)

      config = %{
        "providers" => %{
          "openai" => %{"api_key" => "${OPENAI_API_KEY}", "model" => "gpt-4o-mini"}
        },
        "paths" => %{"home" => "${HOME}"}
      }

      assert %{
               "providers" => %{
                 "openai" => %{"api_key" => "sk-test-openai", "model" => "gpt-4o-mini"}
               },
               "paths" => %{"home" => "${HOME}"}
             } = StartupManager.interpolate_env_vars(config)
    end

    test "returns :missing for unset allowed secret env vars" do
      System.delete_env("ANTHROPIC_API_KEY")

      assert %{"providers" => %{"anthropic" => %{"api_key" => :missing}}} =
               StartupManager.interpolate_env_vars(%{
                 "providers" => %{
                   "anthropic" => %{"api_key" => "${ANTHROPIC_API_KEY}"}
                 }
               })
    end
  end

  describe "validate_required_secrets/1" do
    test "returns missing fields for enabled providers and channels" do
      config = %{
        "providers" => %{
          "openai" => %{"enabled" => true, "api_key" => :missing},
          "anthropic" => %{"enabled" => false, "api_key" => :missing}
        },
        "channels" => %{
          "telegram" => %{"enabled" => true, "bot_token" => :missing},
          "discord" => %{"enabled" => false, "bot_token" => :missing}
        }
      }

      assert {:error, missing_fields} = StartupManager.validate_required_secrets(config)

      assert {"providers.openai.api_key", :missing} in missing_fields
      assert {"channels.telegram.bot_token", :missing} in missing_fields
      refute {"providers.anthropic.api_key", :missing} in missing_fields
      refute {"channels.discord.bot_token", :missing} in missing_fields
    end
  end

  describe "enabled_providers/1" do
    test "returns only enabled providers with resolved secrets" do
      System.put_env("OPENAI_API_KEY", "sk-live-openai")

      on_exit(fn ->
        System.delete_env("OPENAI_API_KEY")
      end)

      config = %{
        "providers" => %{
          "openai" => %{
            "enabled" => true,
            "api_key" => "${OPENAI_API_KEY}",
            "model" => "gpt-4o-mini"
          },
          "anthropic" => %{
            "enabled" => false,
            "api_key" => "${ANTHROPIC_API_KEY}",
            "model" => "claude-3-5-sonnet"
          },
          "ollama" => %{"model" => "llama3"}
        }
      }

      assert [
               {"openai",
                %{"enabled" => true, "api_key" => "sk-live-openai", "model" => "gpt-4o-mini"}}
             ] = StartupManager.enabled_providers(config)
    end

    test "logs warning and skips enabled providers missing required secrets" do
      System.delete_env("OPENAI_API_KEY")

      log =
        capture_log(fn ->
          assert [] =
                   StartupManager.enabled_providers(%{
                     "providers" => %{
                       "openai" => %{"enabled" => true, "api_key" => "${OPENAI_API_KEY}"}
                     }
                   })
        end)

      assert log =~ "Skipping enabled provider openai"
      assert log =~ "providers.openai.api_key"
      refute log =~ "OPENAI_API_KEY"
    end

    test "warns on unknown keys and raises on invalid enabled type" do
      warning_log =
        capture_log(fn ->
          assert [
                   {"openai",
                    %{"enabled" => true, "api_key" => "inline", "unexpected" => "value"}}
                 ] =
                   StartupManager.enabled_providers(%{
                     "providers" => %{
                       "openai" => %{
                         "enabled" => true,
                         "api_key" => "inline",
                         "unexpected" => "value"
                       }
                     }
                   })
        end)

      assert warning_log =~ "Unknown config keys for provider openai: unexpected"

      assert_raise ArgumentError, ~r/providers\.openai\.enabled must be a boolean/, fn ->
        StartupManager.enabled_providers(%{
          "providers" => %{
            "openai" => %{"enabled" => "yes", "api_key" => "inline"}
          }
        })
      end
    end
  end

  describe "enabled_channels/1" do
    test "returns only enabled channels and defaults missing enabled to false" do
      System.put_env("DISCORD_BOT_TOKEN", "discord-token")

      on_exit(fn ->
        System.delete_env("DISCORD_BOT_TOKEN")
      end)

      config = %{
        "channels" => %{
          "cli" => %{"enabled" => true},
          "telegram" => %{"enabled" => false, "bot_token" => "${TELEGRAM_BOT_TOKEN}"},
          "discord" => %{"enabled" => true, "bot_token" => "${DISCORD_BOT_TOKEN}"},
          "slack" => %{"bot_token" => "unused"}
        }
      }

      assert [
               {"cli", %{"enabled" => true}},
               {"discord", %{"enabled" => true, "bot_token" => "discord-token"}}
             ] = StartupManager.enabled_channels(config)
    end

    test "logs warning and skips enabled channels missing required secrets" do
      System.delete_env("TELEGRAM_BOT_TOKEN")

      log =
        capture_log(fn ->
          assert [] =
                   StartupManager.enabled_channels(%{
                     "channels" => %{
                       "telegram" => %{"enabled" => true, "bot_token" => "${TELEGRAM_BOT_TOKEN}"}
                     }
                   })
        end)

      assert log =~ "Skipping enabled channel telegram"
      assert log =~ "channels.telegram.bot_token"
      refute log =~ "TELEGRAM_BOT_TOKEN"
    end
  end
end
