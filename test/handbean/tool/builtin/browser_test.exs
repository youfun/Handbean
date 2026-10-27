defmodule Handbean.Tool.Builtin.BrowserTest do
  @moduledoc """
  Tests for the native `browser` tool contract.

  Execution is stubbed through context.browser_runner so these tests
  never launch Chromium.
  """

  use ExUnit.Case, async: true

  alias Handbean.Tool.Builtin.Browser

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        working_directory: File.cwd!(),
        conversation_id: "conv-browser-test",
        browser_executable: "/usr/bin/agent-browser",
        browser_agent_version: "agent-browser 0.39.1",
        browser_cdp_url: nil
      },
      overrides
    )
  end

  defp ok_runner(text \\ "Example Domain") do
    fn _argv, _opts ->
      {:ok,
       %{
         stdout: Jason.encode!(%{"text" => text}),
         stderr: "",
         exit_code: 0,
         timed_out: false
       }}
    end
  end

  describe "contract" do
    test "exposes a single native browser tool" do
      assert Browser.name() == "browser"
      assert Browser.concurrent?() == false
      assert is_binary(Browser.description())
      assert Browser.description() =~ "web"
      assert Browser.description() =~ "open https://www.google.com/search?q="
      assert Browser.description() =~ "there is no search command"
    end

    test "schema is args plus timeout and session_mode" do
      schema = Browser.input_schema()
      assert schema.type == "object"
      assert schema.required == ["args"]
      assert schema.properties.args.type == "array"
      assert schema.properties.args.description =~ "URL-encoded HTTPS search-results URL"
      assert schema.properties.args.description =~ "there is no search command"
      assert schema.properties.timeout_ms.type == "integer"
      assert schema.properties.session_mode.enum == ["auto", "fresh"]
    end
  end

  describe "execute/2 — validation" do
    test "requires args" do
      assert {:error, reason} = Browser.execute(%{}, context())
      assert reason =~ "args"
    end

    test "denies local file navigation without spawning" do
      runner = fn _argv, _opts ->
        flunk("denied argv must not reach the runner")
      end

      assert {:error, reason, details} =
               Browser.execute(
                 %{"args" => ["open", "file:///etc/passwd"]},
                 context(%{browser_runner: runner})
               )

      assert reason =~ "http"
      assert details.error_command == "open"
      assert details.error_rule == "navigation_scheme"
      assert details.error_argument_role == "url"
    end

    test "rejects caller-owned --session" do
      assert {:error, reason, details} =
               Browser.execute(
                 %{"args" => ["--session", "mine", "snapshot", "-i"]},
                 context(%{browser_runner: ok_runner()})
               )

      assert reason =~ "session"
      assert details.code == :browser_policy_denied
      assert details.error_owner == :browser_policy
      assert details.error_command == "snapshot"
      assert details.error_rule == "forbidden_flag"
      assert details.error_argument_role == "flag"
    end

    test "policy denials never echo the rejected argument" do
      rejected_ref = "@private-selector && printf credential"
      runner = fn _argv, _opts -> flunk("denied argv must not reach the runner") end

      assert {:error, reason, details} =
               Browser.execute(
                 %{"args" => ["fill", rejected_ref, "safe text"]},
                 context(%{browser_runner: runner})
               )

      assert reason ==
               "Browser command denied: shell metacharacters are not allowed in element reference arguments."

      assert details.error_command == "fill"
      assert details.error_rule == "shell_metacharacters"
      assert details.error_argument_role == "ref"
      refute inspect({reason, details}) =~ rejected_ref
      refute inspect({reason, details}) =~ "credential"
    end

    test "denies sensitive local paths without spawning even after approval" do
      runner = fn _argv, _opts ->
        flunk("sensitive browser path must not reach the runner")
      end

      for args <- [
            ["upload", "@e1", "~/.ssh/id_rsa"],
            ["--profile", "work", "upload", "@e1", "~/.ssh/id_rsa"],
            ["screenshot", ".env"],
            ["--screenshot-dir=.ssh", "screenshot"],
            ["pdf", "private/client.key"],
            ["pdf", "--profile", "work", ".env.production"],
            ["download", "@e2", "../secrets/client.p12"]
          ] do
        assert {:error, "sensitive path blocked"} =
                 Browser.execute(
                   %{"args" => args},
                   context(%{browser_runner: runner})
                 )
      end
    end
  end

  describe "execute/2 — injected runner" do
    test "returns structured success details" do
      assert {:ok, content, details} =
               Browser.execute(
                 %{"args" => ["open", "https://example.com"]},
                 context(%{browser_runner: ok_runner()})
               )

      assert content == "Example Domain"
      assert details.result_category == "success"
      assert details.artifacts == []
    end

    test "injects screenshot dir into planned argv" do
      runner = fn argv, _opts ->
        send(self(), {:argv, argv})
        {:ok, %{stdout: ~s({"text":"ok"}), stderr: "", exit_code: 0, timed_out: false}}
      end

      assert {:ok, "ok", _} =
               Browser.execute(
                 %{"args" => ["screenshot"]},
                 context(%{browser_runner: runner, conversation_id: "conv-shot"})
               )

      assert_received {:argv, argv}
      assert "--screenshot-dir" in argv
      dir = argv |> Enum.drop_while(&(&1 != "--screenshot-dir")) |> Enum.at(1)
      assert dir =~ "browser/conv-shot"
    end

    test "injects the connected Chrome relay without exposing CDP flags to callers" do
      runner = fn argv, _opts ->
        send(self(), {:chrome_argv, argv})
        {:ok, %{stdout: ~s({"text":"ok"}), stderr: "", exit_code: 0, timed_out: false}}
      end

      assert {:ok, "ok", _} =
               Browser.execute(
                 %{"args" => ["snapshot", "-i"]},
                 context(%{
                   browser_runner: runner,
                   browser_cdp_url: "ws://127.0.0.1:17643/cdp/internal-token"
                 })
               )

      assert_received {:chrome_argv, argv}

      assert ["--cdp", "ws://127.0.0.1:17643/cdp/internal-token"] =
               Enum.slice(argv, Enum.find_index(argv, &(&1 == "--cdp")), 2)

      assert "--pin-tab" in argv
    end

    test "rejects an incompatible agent-browser before invoking the relay" do
      runner = fn _argv, _opts -> flunk("incompatible agent-browser must not run") end

      assert {:error, reason} =
               Browser.execute(
                 %{"args" => ["snapshot", "-i"]},
                 context(%{
                   browser_runner: runner,
                   browser_agent_version: "agent-browser 0.27.0",
                   browser_cdp_url: "ws://127.0.0.1:17643/cdp/internal-token"
                 })
               )

      assert reason =~ "requires agent-browser 0.39.1 or later"
    end

    test "returns a recoverable missing-binary error" do
      assert {:error, content, details} =
               Browser.execute(
                 %{"args" => ["--version"]},
                 context(%{
                   browser_find_executable: fn _ -> nil end,
                   browser_executable: nil
                 })
               )

      assert content =~ "agent-browser"
      assert details.failure_category == "missing-binary"
      assert [%{id: "install-agent-browser"}] = details.next_actions
    end

    test "maps runner timeout to a structured failure" do
      runner = fn _argv, _opts ->
        {:ok, %{stdout: "partial", stderr: "", exit_code: 0, timed_out: true}}
      end

      assert {:error, content, details} =
               Browser.execute(
                 %{"args" => ["open", "https://example.com"], "timeout_ms" => 1_000},
                 context(%{browser_runner: runner})
               )

      assert content =~ "timed out"
      assert details.failure_category == "timeout"
      assert [%{id: "retry-with-fresh-session"}] = details.next_actions
    end

    test "passes through approved multiline eval as one unchanged argv value" do
      runner = fn argv, _opts ->
        send(self(), {:eval_argv, argv})
        {:ok, %{stdout: ~s({"text":"1"}), stderr: "", exit_code: 0, timed_out: false}}
      end

      script = """
      const text = document.querySelector('#add-project-error')?.textContent ||
        Array.from(document.querySelectorAll('[role=alert]')).map(x => x.textContent).join('|');
      text && `message: ${text}`;
      """

      assert {:prompt, %{capability: :eval}} = Handbean.Browser.Policy.classify(["eval", script])

      assert {:ok, "1", _} =
               Browser.execute(
                 %{"args" => ["eval", script]},
                 context(%{browser_runner: runner})
               )

      assert_received {:eval_argv, argv}
      assert Enum.take(argv, -2) == ["eval", script]
    end

    test "passes #867 fill text and type text through as unchanged argv" do
      runner = fn argv, _opts ->
        send(self(), {:text_argv, argv})
        {:ok, %{stdout: ~s({"text":"ok"}), stderr: "", exit_code: 0, timed_out: false}}
      end

      text =
        "请执行一次真实工具验收……运行这条命令：printf '%s' marker > proof && cat proof\n" <>
          "PowerShell $(Get-Content proof) | Python `print('literal')`"

      for args <- [["fill", "@e26", text], ["type", "@e27", text]] do
        assert {:ok, "ok", _} =
                 Browser.execute(
                   %{"args" => args},
                   context(%{browser_runner: runner})
                 )

        assert_received {:text_argv, argv}
        assert Enum.take(argv, -length(args)) == args
      end
    end
  end
end
