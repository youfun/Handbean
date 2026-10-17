defmodule Handbean.Terminal.EngineIntegrationTest do
  use ExUnit.Case, async: false

  alias Handbean.Terminal.Session

  @moduletag :unix_jobs
  @moduletag :tmp_dir

  test "PTY input, resize and Agent snapshot work without a browser", %{tmp_dir: workspace} do
    workspace_id = "terminal-engine-#{System.unique_integer([:positive])}"
    name = "integration"
    :ok = Phoenix.PubSub.subscribe(Handbean.PubSub, "terminal:#{workspace_id}")

    session =
      start_supervised!(
        {Session,
         workspace_id: workspace_id,
         workspace_path: workspace,
         name: name,
         cmd: "/bin/sh",
         args: ["-c", ~S(stty -echo; IFS= read -r value; printf '\033[31m%s\033[0m\n' "$value")],
         cols: 40,
         rows: 10}
      )

    assert :ok = Session.resize(session, 80, 20)
    assert %{cols: 80, rows: 20} = Session.info(session)

    text = "中文 👩‍💻 e\u0301"
    assert :ok = Session.send_input(session, text <> "\n")
    assert_receive {:terminal_exited, ^workspace_id, ^name, 0}, 5_000

    assert {:ok, snapshot} = Session.snapshot(session)
    assert snapshot =~ text
    refute snapshot =~ "\e[31m"
    assert File.read!(Path.join([workspace, ".handbean", "terminals", "#{name}.log"])) =~ text

    %{term: terminal, pty: pty} = Session.info(session)
    terminal_monitor = Process.monitor(terminal)
    pty_monitor = Process.monitor(pty)
    assert :ok = stop_supervised(Session)
    assert_receive {:DOWN, ^terminal_monitor, :process, ^terminal, _}, 5_000
    assert_receive {:DOWN, ^pty_monitor, :process, ^pty, _}, 5_000
  end

  test "Unicode output survives terminal reflow" do
    terminal = start_supervised!({Ghostty.Terminal, cols: 80, rows: 10})
    text = "中文 👩‍💻 e\u0301 terminal reflow"

    assert :ok = Ghostty.Terminal.write(terminal, "\e[38;2;12;34;56m" <> text <> "\e[0m")
    assert :ok = Ghostty.Terminal.resize(terminal, 12, 10)
    assert :ok = Ghostty.Terminal.resize(terminal, 80, 10)
    assert {:ok, snapshot} = Ghostty.Terminal.snapshot(terminal, :plain)
    assert snapshot =~ text
  end
end
