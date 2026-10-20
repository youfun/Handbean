defmodule Handbean.Browser.CliTest do
  @moduledoc """
  Tests for the agent-browser argv planner and injectable runner.

  No Chromium is launched. The default executable lookup can be stubbed.
  """

  use ExUnit.Case, async: true

  alias Handbean.Browser.Cli

  describe "planned_argv/2" do
    test "injects --json and the managed session" do
      argv = Cli.planned_argv(["open", "https://example.com"], session_name: "handbean-abc")

      assert argv == ["--json", "--session", "handbean-abc", "open", "https://example.com"]
    end

    test "does not inject session or json for inspection" do
      assert Cli.planned_argv(["--help"], session_name: "handbean-abc") == ["--help"]
      assert Cli.planned_argv(["--version"], session_name: "handbean-abc") == ["--version"]
    end

    test "omits --session when no managed session is provided" do
      assert Cli.planned_argv(["snapshot", "-i"], []) == ["--json", "snapshot", "-i"]
    end

    test "injects screenshot dir after session" do
      argv =
        Cli.planned_argv(["screenshot"],
          session_name: "handbean-abc",
          screenshot_dir: "/tmp/handbean-browser"
        )

      assert argv == [
               "--json",
               "--session",
               "handbean-abc",
               "--screenshot-dir",
               "/tmp/handbean-browser",
               "screenshot"
             ]
    end

    test "injects the managed Chrome CDP relay and strict tab pinning" do
      argv =
        Cli.planned_argv(["snapshot", "-i"],
          session_name: "handbean-abc",
          cdp_url: "ws://127.0.0.1:17643/cdp/token",
          pin_tab: true
        )

      assert argv == [
               "--json",
               "--session",
               "handbean-abc",
               "--cdp",
               "ws://127.0.0.1:17643/cdp/token",
               "--pin-tab",
               "snapshot",
               "-i"
             ]
    end

    test "does not inject managed browser flags for inspection" do
      assert Cli.planned_argv(["--version"],
               cdp_url: "ws://127.0.0.1:17643/cdp/token",
               pin_tab: true
             ) == ["--version"]
    end
  end

  describe "chrome_relay_compatibility/1" do
    test "accepts the verified agent-browser version" do
      assert %{
               available: true,
               compatible: true,
               version: "0.39.1",
               minimum_version: "0.39.1"
             } =
               Cli.chrome_relay_compatibility(
                 executable: "/usr/bin/agent-browser",
                 agent_browser_version: "agent-browser 0.39.1"
               )
    end

    test "reports an older version as incompatible" do
      assert %{available: true, compatible: false, version: "0.27.0"} =
               Cli.chrome_relay_compatibility(
                 executable: "/usr/bin/agent-browser",
                 agent_browser_version: "agent-browser 0.27.0"
               )
    end
  end

  describe "run/2" do
    test "calls the injected runner with planned argv and timeout" do
      test_pid = self()

      runner = fn argv, opts ->
        send(test_pid, {:ran, argv, opts})
        {:ok, %{stdout: ~s({"text":"ok"}), stderr: "", exit_code: 0, timed_out: false}}
      end

      assert {:ok, raw} =
               Cli.run(["snapshot", "-i"],
                 session_name: "handbean-1",
                 timeout_ms: 12_000,
                 runner: runner,
                 executable: "/usr/bin/agent-browser"
               )

      assert raw.exit_code == 0
      assert_received {:ran, ["--json", "--session", "handbean-1", "snapshot", "-i"], opts}
      assert opts[:timeout_ms] == 12_000
      assert opts[:executable] == "/usr/bin/agent-browser"
    end

    @tag :tmp_dir
    @tag skip: match?({:win32, _}, :os.type())
    test "direct subprocess receives eval source literally without shell expansion", %{
      tmp_dir: dir
    } do
      executable = Path.join(dir, "argv-echo")
      marker = Path.join(dir, "must-not-exist")
      File.write!(executable, "#!/bin/sh\nprintf '%s\\000' \"$@\"\n")
      File.chmod!(executable, 0o700)

      script = "const text = '$(touch #{marker})';\ntext || `literal`"
      assert {:prompt, %{capability: :eval}} = Handbean.Browser.Policy.classify(["eval", script])

      assert {:ok, %{exit_code: 0, stdout: output}} =
               Cli.run(["eval", script], executable: executable)

      assert String.split(output, <<0>>, trim: true) == ["--json", "eval", script]
      refute File.exists?(marker)
    end

    test "returns missing-binary when the executable cannot be found" do
      find = fn _name -> nil end

      assert {:error, :missing_binary, "agent-browser"} =
               Cli.run(["--version"], find_executable: find)
    end

    test "fails before spawning when the Chrome relay needs a newer agent-browser" do
      runner = fn _argv, _opts -> flunk("incompatible agent-browser must not run") end

      assert {:error, reason} =
               Cli.run(["snapshot", "-i"],
                 cdp_url: "ws://127.0.0.1:17643/cdp/token",
                 pin_tab: true,
                 agent_browser_version: "agent-browser 0.27.0",
                 runner: runner,
                 executable: "/usr/bin/agent-browser"
               )

      assert reason =~ "requires agent-browser 0.39.1 or later"
      assert reason =~ "found 0.27.0"
    end

    test "uses a default timeout when none is supplied" do
      runner = fn _argv, opts ->
        send(self(), {:timeout, opts[:timeout_ms]})
        {:ok, %{stdout: "", stderr: "", exit_code: 0, timed_out: false}}
      end

      assert {:ok, %{exit_code: 0}} =
               Cli.run(["--help"], runner: runner, executable: "/usr/bin/agent-browser")

      assert_received {:timeout, 35_000}
    end
  end
end
