defmodule Handbean.Tool.Builtin.BrowserSessionTest do
  @moduledoc """
  Tests that the browser tool injects the OTP-managed session name.
  """

  use ExUnit.Case, async: false

  alias Handbean.Browser.{Registry, Session, Supervisor}
  alias Handbean.Tool.Builtin.Browser

  setup_all do
    unless Process.whereis(Registry) do
      {:ok, _} = Registry.start_link()
    end

    unless Process.whereis(Supervisor) do
      {:ok, _} = Supervisor.start_link()
    end

    :ok
  end

  setup do
    conversation_id = "conv-tool-#{System.unique_integer([:positive])}"
    on_exit(fn -> Supervisor.stop_session(conversation_id) end)
    %{conversation_id: conversation_id}
  end

  test "auto mode injects the managed --session", %{conversation_id: conversation_id} do
    {:ok, %{name: name}} = Session.ensure(conversation_id, "auto")
    test_pid = self()

    runner = fn argv, _opts ->
      send(test_pid, {:argv, argv})
      {:ok, %{stdout: ~s({"text":"ok"}), stderr: "", exit_code: 0, timed_out: false}}
    end

    assert {:ok, "ok", _} =
             Browser.execute(
               %{"args" => ["snapshot", "-i"], "session_mode" => "auto"},
               %{
                 conversation_id: conversation_id,
                 browser_runner: runner,
                 browser_executable: "/usr/bin/agent-browser"
               }
             )

    assert_received {:argv, argv}
    assert ["--json", "--session", ^name, "--screenshot-dir", dir, "snapshot", "-i"] = argv
    assert dir =~ conversation_id
  end

  test "inspection does not consume the managed session", %{conversation_id: conversation_id} do
    runner = fn argv, _opts ->
      send(self(), {:argv, argv})
      {:ok, %{stdout: "agent-browser 0.1\n", stderr: "", exit_code: 0, timed_out: false}}
    end

    assert {:ok, content, _} =
             Browser.execute(
               %{"args" => ["--version"]},
               %{
                 conversation_id: conversation_id,
                 browser_runner: runner,
                 browser_executable: "/usr/bin/agent-browser"
               }
             )

    assert content =~ "agent-browser"
    assert_received {:argv, ["--version"]}
    assert {:error, :not_found} = Registry.lookup(conversation_id, "default")
  end
end
