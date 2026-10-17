defmodule HandbeanWeb.ScratchSwitchDuringCliRunTest do
  @moduledoc false

  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Handbean.Agent.CliAgent.Registry
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  setup do
    E2EHarness.isolate_home!("scratch-switch")
    E2EHarness.use_fake_provider!(:simple_answer)
    Registry.reset()
    Application.delete_env(:handbean, :fake_cli_notify)

    on_exit(fn ->
      for conversation <- Handbean.ConversationStore.list(include_timeline?: false) do
        E2EHarness.cancel!(conversation["id"])
      end

      Registry.reset()
      Application.delete_env(:handbean, :fake_cli_notify)
    end)

    :ok
  end

  defp first_conversation_id(view) do
    :sys.get_state(view.pid).socket.assigns.current_conversation_id
  end

  test "switching to an existing conversation while a CLI run is active", %{conn: conn} do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    # Conversation B: an existing conversation with a completed Handbean run.
    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    conv_b = first_conversation_id(view)
    :ok = Session.subscribe(conv_b)

    view
    |> form("#composer", %{message: "prior exchange"})
    |> render_submit()

    assert E2EHarness.await_run_end(conv_b)[:status] == :completed
    assert render(view) =~ "prior exchange"
    assert Session.whereis(conv_b) != nil

    # Conversation A: a new conversation that starts a slow CLI run.
    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    conv_a = first_conversation_id(view)
    view |> element("#cli-picker") |> render_change(%{"cli" => "fake-cli"})

    view
    |> form("#composer", %{message: "slow", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_waiting, task}
    task_ref = Process.monitor(task)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.running
    assert assigns.running_conversation_id == conv_a
    assert has_element?(view, "#agent-working")

    # The user's action: click the existing conversation B in the sidebar.
    html =
      view
      |> element("#conversation-#{conv_b} button[phx-click='select_conversation']")
      |> render_click()

    current = first_conversation_id(view)
    IO.inspect({:switched_to, current, :expected, conv_b, :path_patched?, html =~ "prior exchange"}, label: "switch-result")

    # Switching back to A must also work and show the still-running state.
    html =
      view
      |> element("#conversation-#{conv_a} button[phx-click='select_conversation']")
      |> render_click()

    IO.inspect({:switched_back_to, first_conversation_id(view)}, label: "switch-back-result")
    assert has_element?(view, "#agent-working")

    send(task, :finish_fake_cli)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, 1_000
    _ = html
  end
end
