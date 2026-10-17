defmodule HandbeanWeb.CliComposerLiveTest do
  @moduledoc """
  Composer loop-owner choice.

  No CLI selected keeps Handbean's model list and Provider path. Selecting a
  registered CLI swaps that list for the CLI's own models and sends through
  `Handbean.Agent.CliAgent.Run`.
  """

  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Handbean.Agent.CliAgent.Registry
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness
  alias HandbeanWeb.WorkspaceLive.CliSelection

  setup do
    E2EHarness.isolate_home!("cli-composer")
    E2EHarness.use_fake_provider!(:simple_answer)
    Registry.reset()
    Application.delete_env(:handbean, :fake_cli_notify)
    Application.delete_env(:handbean, :slow_cli_models_notify)

    on_exit(fn ->
      for conversation <- Handbean.ConversationStore.list(include_timeline?: false) do
        E2EHarness.cancel!(conversation["id"])
      end

      Registry.reset()
      Application.delete_env(:handbean, :fake_cli_notify)
      Application.delete_env(:handbean, :slow_cli_models_notify)
    end)

    :ok
  end

  test "CLI picker labels capitalize the first letter of the backend id" do
    assert CliSelection.display_name("droid") == "Droid"
    assert CliSelection.display_name("grok") == "Grok"
  end

  test "default send keeps the Handbean model picker and does not call a CLI", %{conn: conn} do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="cli-picker")
    assert html =~ "Handbean"
    assert has_element?(view, "#cli-picker option[value='fake-cli']", "Fake-cli")
    assert html =~ ~s(id="model-picker")
    assert html =~ ~s(id="model-picker-trigger")
    assert html =~ ~s(phx-hook="ModelPicker")
    assert has_element?(view, "#model-picker option[value='fake/fake-model']")
    refute has_element?(view, "#cli-model-picker")

    view
    |> form("#composer", %{message: "hello handbean"})
    |> render_submit()

    refute_received {:fake_cli_turn, _, _}
    assert render(view) =~ "hello handbean"
    assert has_element?(view, "#model-picker")
    refute has_element?(view, "#cli-model-picker")
  end

  test "selecting a CLI swaps the model list and send uses the CLI run path", %{conn: conn} do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    html = select_cli(view, "fake-cli")

    assert html =~ "fake-model"
    assert html =~ "Fake"
    refute html =~ ~s(id="cli-models-error")

    view
    |> form("#composer", %{message: "hello cli", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "hello cli", session}
    assert session.backend == "fake-cli"
    assert render(view) =~ "fake"
  end

  test "switching away and back keeps the CLI model and reasoning", %{conn: conn} do
    Registry.register(HandbeanWeb.CliComposerLiveTest.TwoModels)
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    other_id = first_conversation_id(view)

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    cli_id = first_conversation_id(view)
    refute cli_id == other_id

    select_cli(view, "two-cli")
    view |> element("#cli-model-picker") |> render_change(%{"model" => "model-b"})
    view |> element("#reasoning-picker") |> render_change(%{"reasoning" => "off"})

    view
    |> element("#conversation-#{other_id} button[phx-click='select_conversation']")
    |> render_click()

    assert first_conversation_id(view) == other_id
    assert has_element?(view, "#model-picker")
    refute has_element?(view, "#cli-model-picker")

    view
    |> element("#conversation-#{cli_id} button[phx-click='select_conversation']")
    |> render_click()

    assert first_conversation_id(view) == cli_id
    assert has_element?(view, "#cli-picker option[value='two-cli'][selected]")
    assert has_element?(view, "#cli-model-picker option[value='model-b'][selected]")
    assert has_element?(view, "#reasoning-picker option[value='off'][selected]")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.selected_cli == "two-cli"
    assert assigns.selected_model == "model-b"
    assert assigns.selected_reasoning_level == "off"
  end

  test "a CLI model list that finishes while away is restored on return", %{conn: conn} do
    Registry.register(HandbeanWeb.CliComposerLiveTest.SlowModels)
    Application.put_env(:handbean, :slow_cli_models_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    other_id = first_conversation_id(view)

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    cli_id = first_conversation_id(view)

    view |> element("#cli-picker") |> render_change(%{"cli" => "slow-models"})
    assert_receive {:slow_cli_models_started, loader}

    view
    |> element("#conversation-#{other_id} button[phx-click='select_conversation']")
    |> render_click()

    send(loader, :finish_slow_cli_models)
    render_async(view, 5_000)
    refute has_element?(view, "#cli-model-picker option[value='slow-model']")

    view
    |> element("#conversation-#{cli_id} button[phx-click='select_conversation']")
    |> render_click()

    assert has_element?(view, "#cli-picker option[value='slow-models'][selected]")
    assert has_element?(view, "#cli-model-picker option[value='slow-model'][selected]")
  end

  test "loading CLI models does not block switching conversations", %{conn: conn} do
    Registry.register(HandbeanWeb.CliComposerLiveTest.SlowModels)
    Application.put_env(:handbean, :slow_cli_models_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    first_conversation_id = first_conversation_id(view)

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    refute first_conversation_id(view) == first_conversation_id

    selection =
      Task.async(fn ->
        view
        |> element("#cli-picker")
        |> render_change(%{"cli" => "slow-models"})
      end)

    assert_receive {:slow_cli_models_started, loader}
    selection_result = Task.yield(selection, 500)

    if is_nil(selection_result), do: send(loader, :finish_slow_cli_models)

    assert {:ok, html} = selection_result
    assert html =~ ~s(id="cli-models-loading")

    view
    |> element("#conversation-#{first_conversation_id} button[phx-click='select_conversation']")
    |> render_click()

    assert first_conversation_id(view) == first_conversation_id
    send(loader, :finish_slow_cli_models)

    html = render_async(view, 5_000)
    refute has_element?(view, "#cli-model-picker option[value='slow-model']")
    refute html =~ ~s(id="cli-models-loading")
    assert has_element?(view, "#model-picker")
  end

  test "a second message reuses the CLI session and switching does not", %{conn: conn} do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "slow", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "slow", first}
    assert_receive {:fake_cli_waiting, task}
    assert first.session_id == "fake-new"
    assert first.private.resumed == nil

    conversation_id = first_conversation_id(view)
    [{runner, _metadata}] = Elixir.Registry.lookup(Handbean.AgentRunRegistry, conversation_id)
    runner_ref = Process.monitor(runner)
    send(task, :finish_fake_cli)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, _reason}

    view
    |> form("#composer", %{message: "second", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "second", second}
    assert second.session_id == "fake-new"
    assert second.private.resumed == "fake-new"
    assert :ok = Handbean.Agent.CliAgent.Runner.await_stop(conversation_id)

    view |> element("#cli-picker") |> render_change(%{"cli" => ""})
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "fresh", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "fresh", fresh}
    assert fresh.private.resumed == nil
  end

  test "a CLI permission renders as a pending approval and only an offered option resumes", %{
    conn: conn
  } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "need-permission", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "need-permission", _}
    html = render(view)
    assert html =~ "tool-approval-overlay"
    assert html =~ "CLI approval required"
    assert html =~ "Edit"
    assert html =~ "lib/demo.ex"
    assert has_element?(view, "#cli-approval-proceed_once")

    view |> element("button[phx-click=deny_all_tools]") |> render_click()

    refute_received {:fake_cli_turn, "need-permission", %{private: %{decision: _}}}
    assert render(view) =~ "CLI turn stopped"
    refute has_element?(view, "#tool-approval-overlay")
  end

  test "choosing an offered CLI option resumes that session", %{conn: conn} do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "need-permission", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "need-permission", asked}
    assert has_element?(view, "#cli-approval-proceed_once")

    view |> element("#cli-approval-proceed_once") |> render_click()

    assert_receive {:fake_cli_turn, "need-permission", resumed}
    assert resumed.session_id == asked.session_id
    assert resumed.private.decision == {:permission, "proceed_once"}
    assert render(view) =~ "fake"
    refute has_element?(view, "#tool-approval-overlay")
  end

  test "cross-sender CLI events are durably ordered before run_end", %{conn: conn} do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    conversation_id = first_conversation_id(view)
    :ok = Session.subscribe(conversation_id)
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{
      message: "ordered-cross-sender",
      cli: "fake-cli",
      model: "fake-model"
    })
    |> render_submit()

    assert_receive {:agent_event, %{kind: :run_start, payload: %{run_id: run_id}}}
    assert_receive {:fake_cli_event_ready, emitter}
    send(emitter, :emit_cli_events)
    assert_receive :fake_cli_event_callbacks_returned

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{run_id: ^run_id, chunk: "ordered"}}}

    assert_receive {:agent_event,
                    %{kind: :tool_start, payload: %{run_id: ^run_id, id: "ordered-tool"}}}

    assert_receive {:agent_event,
                    %{kind: :tool_end, payload: %{run_id: ^run_id, id: "ordered-tool"}}}

    assert_receive {:agent_event, %{kind: :turn_end, payload: %{run_id: ^run_id}}}

    assert_receive {:agent_event,
                    %{kind: :run_end, payload: %{run_id: ^run_id, status: :completed}}}

    {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)

    assert Enum.any?(entries, fn entry ->
             entry["role"] == "assistant" and entry["content"] == "ordered" and
               entry["status"] == "completed" and entry["run_id"] == run_id
           end)

    assert Enum.any?(entries, fn entry ->
             entry["content_type"] == "tool" and entry["tool_status"] == "done" and
               entry["run_id"] == run_id
           end)
  end

  test "backend error emits one persisted and broadcast run_end with complete metadata", %{
    conn: conn
  } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    conversation_id = first_conversation_id(view)
    :ok = Session.subscribe(conversation_id)
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "return-error", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:agent_event, %{kind: :run_start, payload: %{run_id: run_id}}}

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{
                        status: :error,
                        error: "fake_failure",
                        run_id: ^run_id,
                        loop_owner: :cli_agent,
                        backend: "fake-cli",
                        turns: 0
                      }
                    }}

    refute_receive {:agent_event, %{kind: :run_end, payload: %{run_id: ^run_id}}}, 100
    {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)

    assert Enum.any?(entries, fn entry ->
             entry["message_type"] == "error" and entry["run_id"] == run_id
           end)
  end

  test "backend task crash emits one persisted and broadcast run_end with complete metadata", %{
    conn: conn
  } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    conversation_id = first_conversation_id(view)
    :ok = Session.subscribe(conversation_id)
    select_cli(view, "fake-cli")

    ExUnit.CaptureLog.capture_log(fn ->
      view
      |> form("#composer", %{message: "crash", cli: "fake-cli", model: "fake-model"})
      |> render_submit()

      assert_receive {:agent_event, %{kind: :run_start, payload: %{run_id: run_id}}}

      assert_receive {:agent_event,
                      %{
                        kind: :run_end,
                        payload: %{
                          status: :error,
                          error: error,
                          run_id: ^run_id,
                          loop_owner: :cli_agent,
                          backend: "fake-cli",
                          turns: 0
                        }
                      }},
                     1_000

      assert error =~ "fake cli crash"
      refute_receive {:agent_event, %{kind: :run_end, payload: %{run_id: ^run_id}}}, 100
      {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)

      assert Enum.any?(entries, fn entry ->
               entry["message_type"] == "error" and entry["run_id"] == run_id
             end)
    end)
  end

  test "approval resume keeps one logical run and emits one complete terminal payload", %{
    conn: conn
  } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    conversation_id = first_conversation_id(view)
    :ok = Session.subscribe(conversation_id)
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{
      message: "need-permission",
      cli: "fake-cli",
      model: "fake-model"
    })
    |> render_submit()

    assert_receive {:agent_event,
                    %{
                      kind: :run_start,
                      payload: %{
                        run_id: run_id,
                        loop_owner: :cli_agent,
                        backend: "fake-cli"
                      }
                    }}

    assert_receive {:fake_cli_turn, "need-permission", asked}
    assert has_element?(view, "#cli-approval-proceed_once")
    view |> element("#cli-approval-proceed_once") |> render_click()
    assert_receive {:fake_cli_turn, "need-permission", resumed}
    assert resumed.session_id == asked.session_id

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{
                        status: :completed,
                        run_id: ^run_id,
                        loop_owner: :cli_agent,
                        backend: "fake-cli",
                        turns: 1
                      }
                    }},
                   1_000

    refute_receive {:agent_event, %{kind: :run_start, payload: %{run_id: ^run_id}}}, 100
    refute_receive {:agent_event, %{kind: :run_end, payload: %{run_id: ^run_id}}}, 100

    {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)

    assert Enum.any?(entries, fn entry ->
             entry["role"] == "assistant" and entry["content"] == "fake" and
               entry["status"] == "completed" and entry["run_id"] == run_id
           end)
  end

  test "cancelling streamed CLI text settles that assistant and emits one matching run_end", %{
    conn: conn
  } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    conversation_id = first_conversation_id(view)
    :ok = Session.subscribe(conversation_id)
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "streaming-slow", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:agent_event,
                    %{kind: :run_start, payload: %{run_id: run_id, loop_owner: :cli_agent}}}

    assert_receive {:fake_cli_waiting, task}
    task_ref = Process.monitor(task)

    assert_receive {:agent_event,
                    %{kind: :message_delta, payload: %{run_id: ^run_id, chunk: "partial"}}}

    view |> element("button[phx-click='stop_run']") |> render_click()
    assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, 1_000

    assert_receive {:agent_event,
                    %{
                      kind: :run_end,
                      payload: %{
                        status: :cancelled,
                        run_id: ^run_id,
                        loop_owner: :cli_agent,
                        backend: "fake-cli",
                        turns: 0
                      }
                    }},
                   1_000

    refute_receive {:agent_event, %{kind: :run_end, payload: %{run_id: ^run_id}}}, 100

    {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)

    assert Enum.any?(entries, fn entry ->
             entry["role"] == "assistant" and entry["content"] == "partial" and
               entry["status"] == "cancelled" and entry["run_id"] == run_id
           end)
  end

  test "switching to Handbean during a CLI run rejects queueing and retains the draft", %{
    conn: conn
  } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "slow", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_waiting, task}
    conversation_id = first_conversation_id(view)
    view |> element("#cli-picker") |> render_change(%{"cli" => ""})
    render_keyup(view, "update_input", %{"value" => "keep while cli runs"})

    view
    |> form("#composer", %{message: "keep while cli runs", model: "fake/fake-model"})
    |> render_submit()

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.input_value == "keep while cli runs"
    assert assigns.composer_error =~ "Stop the active CLI run"
    assert Process.alive?(task)

    {:ok, entries} = Handbean.ConversationTranscriptStore.list(conversation_id)
    refute Enum.any?(entries, &(&1["content"] == "keep while cli runs"))

    view |> element("button[phx-click='stop_run']") |> render_click()
  end

  test "slow CLI remains supervised while switching and Stop cancels it", %{conn: conn} do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "slow", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_waiting, task}
    task_ref = Process.monitor(task)
    conversation_id = first_conversation_id(view)

    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    refute first_conversation_id(view) == conversation_id
    assert Process.alive?(task)

    {:ok, reconnected, _html} = live(conn, "/w/default/c/#{conversation_id}")
    assert has_element?(reconnected, "button[phx-click='stop_run']")

    reconnected |> element("button[phx-click='stop_run']") |> render_click()
    assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}
    refute has_element?(reconnected, "button[phx-click='stop_run']")
  end

  test "unsupported CLI attachments are rejected without clearing draft or attachments", %{
    conn: conn
  } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    select_cli(view, "fake-cli")

    attachment = %{"id" => "kept", "filename" => "kept.png", "url" => "/uploads/kept.png"}

    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      socket =
        socket
        |> Phoenix.Component.assign(:input_value, "keep this draft")
        |> Phoenix.Component.assign(:pending_attachments, [attachment])

      %{state | socket: socket}
    end)

    view
    |> form("#composer", %{
      message: "keep this draft",
      cli: "fake-cli",
      model: "fake-model"
    })
    |> render_submit()

    refute_received {:fake_cli_turn, _, _}
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.input_value == "keep this draft"
    assert assigns.pending_attachments == [attachment]
    assert assigns.composer_error =~ "does not support attachments"
  end

  test "new Handbean run rejection retains input and remembered draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    conversation_id = first_conversation_id(view)
    previous = Application.get_env(:handbean, :conversation_transcript_store)

    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      socket =
        socket
        |> Phoenix.Component.assign(:input_value, "retry after rejection")
        |> Phoenix.Component.assign(:composer_drafts, %{
          conversation_id => %{input: "retry after rejection", attachments: []}
        })

      %{state | socket: socket}
    end)

    Application.put_env(
      :handbean,
      :conversation_transcript_store,
      HandbeanWeb.CliComposerLiveTest.RefusingTranscriptStore
    )

    try do
      view
      |> form("#composer", %{message: "retry after rejection", model: "fake/fake-model"})
      |> render_submit()

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "retry after rejection"
      assert assigns.composer_drafts[conversation_id].input == "retry after rejection"
      assert assigns.composer_error =~ "Message not delivered"
      refute assigns.running
    after
      if previous,
        do: Application.put_env(:handbean, :conversation_transcript_store, previous),
        else: Application.delete_env(:handbean, :conversation_transcript_store)
    end
  end

  test "a CLI that cannot list models does not fall back to the Handbean catalog", %{conn: conn} do
    Registry.register(HandbeanWeb.CliComposerLiveTest.UnavailableModels)
    {:ok, view, _html} = live(conn, "/")

    html = select_cli(view, "silent-cli")

    assert html =~ "This CLI cannot list models."
    refute html =~ "fake-model"
    assert has_element?(view, "#cli-models-error")
  end

  test "CLI session_state status is projected in the working indicator and recovered on reconnect",
       %{
         conn: conn
       } do
    Registry.register(Handbean.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbean, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    select_cli(view, "fake-cli")

    view
    |> form("#composer", %{message: "status-slow", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_waiting, task}
    conversation_id = first_conversation_id(view)

    html = render(view)
    assert html =~ ~s(id="agent-working-detail")
    assert html =~ "compacting"

    assert {:ok, status} = Handbean.Agent.Coordinator.status(conversation_id)
    assert status.loop_owner == :cli_agent
    assert status.status_detail == "compacting"

    {:ok, reconnected, reconnected_html} = live(conn, "/w/default/c/#{conversation_id}")
    assert reconnected_html =~ "compacting"
    assert has_element?(reconnected, "#agent-working-detail")

    [{runner, _metadata}] = Elixir.Registry.lookup(Handbean.AgentRunRegistry, conversation_id)
    runner_ref = Process.monitor(runner)
    send(task, :finish_fake_cli)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, _reason}

    refute has_element?(reconnected, "#agent-working-detail")
  end

  defp first_conversation_id(view) do
    :sys.get_state(view.pid).socket.assigns.current_conversation_id
  end

  defp select_cli(view, cli) do
    view |> element("#cli-picker") |> render_change(%{"cli" => cli})
    render_async(view, 5_000)
  end
end

defmodule HandbeanWeb.CliComposerLiveTest.RefusingTranscriptStore do
  @moduledoc false
  @behaviour Handbean.ConversationTranscriptStore

  alias Handbean.ConversationTranscriptStore.ConversationStore

  def list(conversation_id, opts), do: ConversationStore.list(conversation_id, opts)
  def page(conversation_id, opts), do: ConversationStore.page(conversation_id, opts)
  def append(_conversation_id, _entry, _opts), do: {:error, :storage_unavailable}

  def append_with_receipt(_conversation_id, _entry, _request_id, _receipt, _opts),
    do: {:error, :storage_unavailable}

  def update(conversation_id, entry_id, patch, opts),
    do: ConversationStore.update(conversation_id, entry_id, patch, opts)

  def delete(conversation_id, entry_id, opts),
    do: ConversationStore.delete(conversation_id, entry_id, opts)

  def replace_all(conversation_id, entries, opts),
    do: ConversationStore.replace_all(conversation_id, entries, opts)
end

defmodule HandbeanWeb.CliComposerLiveTest.TwoModels do
  @moduledoc false
  @behaviour Handbean.Agent.CliAgent

  alias Handbean.Agent.CliAgent.Session

  @impl true
  def id, do: "two-cli"
  @impl true
  def available?, do: true

  @impl true
  def list_models(_opts) do
    {:ok,
     [
       %{id: "model-a", display_name: "Model A", reasoning_levels: ["low", "off"]},
       %{id: "model-b", display_name: "Model B", reasoning_levels: ["low", "off"]}
     ]}
  end

  @impl true
  def start_session(opts) do
    {:ok, %Session{backend: id(), cwd: Keyword.get(opts, :cwd, ".")}}
  end

  @impl true
  def send_message(session, _text, _on_event), do: {:ok, session, []}
  @impl true
  def interrupt(_session), do: :ok
  @impl true
  def update_model(session, _opts), do: {:ok, session}
  @impl true
  def stop_session(_session), do: :ok
end

defmodule HandbeanWeb.CliComposerLiveTest.UnavailableModels do
  @moduledoc false
  @behaviour Handbean.Agent.CliAgent

  alias Handbean.Agent.CliAgent.Session

  @impl true
  def id, do: "silent-cli"
  @impl true
  def available?, do: true
  @impl true
  def list_models(_opts), do: {:error, :models_unavailable}

  @impl true
  def start_session(opts) do
    {:ok, %Session{backend: id(), cwd: Keyword.get(opts, :cwd, ".")}}
  end

  @impl true
  def send_message(session, _text, on_event) do
    on_event.({:text_delta, "no"})
    {:ok, session, []}
  end

  @impl true
  def interrupt(_session), do: :ok
  @impl true
  def update_model(session, _opts), do: {:ok, session}
  @impl true
  def stop_session(_session), do: :ok
end

defmodule HandbeanWeb.CliComposerLiveTest.SlowModels do
  @moduledoc false
  @behaviour Handbean.Agent.CliAgent

  alias Handbean.Agent.CliAgent.Session

  @impl true
  def id, do: "slow-models"
  @impl true
  def available?, do: true

  @impl true
  def list_models(_opts) do
    notify = Application.fetch_env!(:handbean, :slow_cli_models_notify)
    send(notify, {:slow_cli_models_started, self()})

    receive do
      :finish_slow_cli_models ->
        {:ok, [%{id: "slow-model", display_name: "Slow", reasoning_levels: []}]}
    end
  end

  @impl true
  def start_session(opts) do
    {:ok, %Session{backend: id(), cwd: Keyword.get(opts, :cwd, ".")}}
  end

  @impl true
  def send_message(session, _text, _on_event), do: {:ok, session, []}
  @impl true
  def interrupt(_session), do: :ok
  @impl true
  def update_model(session, _opts), do: {:ok, session}
  @impl true
  def stop_session(_session), do: :ok
end
