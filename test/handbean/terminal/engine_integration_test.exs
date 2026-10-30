defmodule Handbean.Terminal.EngineIntegrationTest do
  use ExUnit.Case, async: false

  alias Handbean.Platform
  alias Handbean.Terminal.{Session, Supervisor}

  @moduletag :tmp_dir

  test "PTY input, resize and Agent snapshot work without a browser", %{tmp_dir: workspace} do
    workspace_id = "terminal-engine-#{System.unique_integer([:positive])}"
    name = "integration"
    {:ok, checkout} = Handbean.CheckoutScope.resolve(workspace)
    {cmd, args} = ansi_echo_command()

    :ok =
      Phoenix.PubSub.subscribe(
        Handbean.PubSub,
        Handbean.CheckoutScope.terminal_topic(workspace_id, checkout.key)
      )

    session =
      start_supervised!(
        {Session,
         workspace_id: workspace_id,
         checkout_key: checkout.key,
         checkout_path: checkout.path,
         name: name,
         cmd: cmd,
         args: args,
         cols: 40,
         rows: 10}
      )

    assert :ok = Session.resize(session, 80, 20)
    assert %{cols: 80, rows: 20} = Session.info(session)

    text = "中文 👩‍💻 e\u0301"
    assert :ok = Session.send_input(session, text <> "\n")
    assert_receive {:terminal_exited, ^workspace_id, checkout_key, ^name, 0}, 5_000
    assert checkout_key == checkout.key

    assert {:ok, snapshot} = Session.snapshot(session)
    assert snapshot =~ text
    refute snapshot =~ "\e[31m"

    assert File.read!(Path.join([checkout.path, ".handbean", "terminals", "#{name}.log"])) =~
             text

    %{term: terminal, pty: pty} = Session.info(session)
    terminal_monitor = Process.monitor(terminal)
    pty_monitor = Process.monitor(pty)
    assert :ok = stop_supervised(Session)
    assert_receive {:DOWN, ^terminal_monitor, :process, ^terminal, _}, 5_000
    assert_receive {:DOWN, ^pty_monitor, :process, ^pty, _}, 5_000
  end

  test "supervisor scopes creation, lookup and closing to a checkout", %{tmp_dir: workspace} do
    workspace_id = "terminal-scope-#{System.unique_integer([:positive])}"
    first_checkout = Path.join(workspace, "first")
    second_checkout = Path.join(workspace, "second")
    File.mkdir_p!(first_checkout)
    File.mkdir_p!(second_checkout)

    {cmd, args} = blocking_command()
    opts = [cmd: cmd, args: args]

    on_exit(fn -> Supervisor.stop_all_for_workspace(workspace_id) end)

    assert {:ok, first} = Supervisor.start_terminal(workspace_id, first_checkout, "shell", opts)
    assert {:ok, second} = Supervisor.start_terminal(workspace_id, second_checkout, "shell", opts)
    assert first != second

    assert {:error, :already_exists} =
             Supervisor.start_terminal(workspace_id, first_checkout, "shell", opts)

    assert {:ok, ^first} = Supervisor.lookup(workspace_id, first_checkout, "shell")
    assert {:ok, ^second} = Supervisor.lookup(workspace_id, second_checkout, "shell")
    assert [%{name: "shell"}] = Supervisor.list_terminals(workspace_id, first_checkout)
    assert [%{name: "shell"}] = Supervisor.list_terminals(workspace_id, second_checkout)

    monitor = Process.monitor(first)
    assert :ok = Supervisor.stop_terminal(workspace_id, first_checkout, "shell")
    assert_receive {:DOWN, ^monitor, :process, ^first, :shutdown}
    assert {:error, :not_found} = Supervisor.lookup(workspace_id, first_checkout, "shell")
    assert [] = Supervisor.list_terminals(workspace_id, first_checkout)
    assert {:ok, ^second} = Supervisor.lookup(workspace_id, second_checkout, "shell")
    assert Process.alive?(second)
  end

  test "default shell session starts in checkout cwd and accepts newline input", %{
    tmp_dir: workspace
  } do
    workspace_id = "terminal-shell-#{System.unique_integer([:positive])}"
    {:ok, checkout} = Handbean.CheckoutScope.resolve(workspace)

    :ok =
      Phoenix.PubSub.subscribe(
        Handbean.PubSub,
        Handbean.CheckoutScope.terminal_topic(workspace_id, checkout.key)
      )

    session =
      start_supervised!(
        {Session,
         workspace_id: workspace_id,
         checkout_key: checkout.key,
         checkout_path: checkout.path,
         name: "shell",
         cols: 120,
         rows: 24}
      )

    marker = "HANDBEAN_SHELL_OK_#{System.unique_integer([:positive])}"
    assert :ok = Session.send_input(session, "echo #{marker}\n")

    await_snapshot(session, marker)
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

  defp ansi_echo_command do
    if Platform.windows?() do
      {"powershell.exe",
       [
         "-NoLogo",
         "-NoProfile",
         "-Command",
         "[Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $v = [Console]::In.ReadLine(); [Console]::Out.Write(\"$([char]27)[31m$v$([char]27)[0m`r`n\")"
       ]}
    else
      {"/bin/sh",
       ["-c", ~S(stty -echo; IFS= read -r value; printf '\033[31m%s\033[0m\n' "$value")]}
    end
  end

  defp blocking_command do
    if Platform.windows?() do
      {"cmd.exe", []}
    else
      {"/bin/sh", ["-c", "read -r value"]}
    end
  end

  defp await_snapshot(session, expected, attempts \\ 50)

  defp await_snapshot(session, expected, 0) do
    {:ok, snapshot} = Session.snapshot(session)
    flunk("Timed out waiting for #{inspect(expected)} in terminal snapshot:\n#{snapshot}")
  end

  defp await_snapshot(session, expected, attempts) do
    {:ok, snapshot} = Session.snapshot(session)

    if snapshot =~ expected do
      :ok
    else
      receive do
        {:terminal_refresh, _, _, _} -> await_snapshot(session, expected, attempts - 1)
      after
        100 -> await_snapshot(session, expected, attempts - 1)
      end
    end
  end
end
