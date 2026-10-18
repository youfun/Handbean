defmodule Handbean.Browser.InstallPromptTest do
  @moduledoc """
  Tests for the user-facing missing-binary install card.

  The prompt is derived from tool details. It must not install anything
  and must stay hidden for ordinary browser errors.
  """

  use ExUnit.Case, async: true

  alias Handbean.Browser.{InstallPrompt, Result}

  describe "from_details/1" do
    test "builds a copyable install card from missing-binary details" do
      parsed = Result.missing_binary("agent-browser")

      prompt = InstallPrompt.from_details(parsed.details)

      assert prompt.title =~ "agent-browser"
      assert prompt.command == InstallPrompt.command()
      assert prompt.command == "npm install -g agent-browser && agent-browser install"
      assert prompt.hint =~ "each computer"
      assert prompt.hint =~ "another machine"
      assert prompt.hint =~ "login-shell environment"
    end

    test "accepts string-keyed details from transcript restore" do
      prompt =
        InstallPrompt.from_details(%{
          "failure_category" => "missing-binary",
          "next_actions" => [%{"id" => "install-agent-browser"}]
        })

      assert prompt.command == InstallPrompt.command()
    end

    test "returns nil for other failures and empty input" do
      assert InstallPrompt.from_details(%{failure_category: "timeout"}) == nil
      assert InstallPrompt.from_details(%{"failure_category" => "upstream-error"}) == nil
      assert InstallPrompt.from_details(%{}) == nil
      assert InstallPrompt.from_details(nil) == nil
    end
  end

  describe "from_entry/1" do
    test "reads details from a timeline tool entry" do
      entry = %{
        "content_type" => "tool",
        "tool" => "browser",
        "details" => %{failure_category: "missing-binary"}
      }

      assert InstallPrompt.from_entry(entry).command == InstallPrompt.command()
    end

    test "returns nil when the entry has no missing-binary details" do
      assert InstallPrompt.from_entry(%{"tool" => "browser", "error" => "selector not found"}) ==
               nil
    end
  end

  describe "Result.missing_binary/1" do
    test "exposes install_command for UI and a model-facing recipe" do
      parsed = Result.missing_binary("agent-browser")

      assert parsed.details.install_command == InstallPrompt.command()

      assert parsed.content =~ "npm install -g agent-browser && agent-browser install"
      assert parsed.content =~ "more than one computer"
      assert parsed.content =~ "mise, asdf, or direnv"
      assert parsed.content =~ "Do not install it with the bash tool"
      assert parsed.content =~ "another computer"
    end
  end
end
