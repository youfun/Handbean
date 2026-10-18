defmodule HandbeanWeb.WorkspaceLiveTest do
  @moduledoc """
  Tests for the WorkspaceLive — the main three-column Handbean workspace.

  Reference: `beam_scriber/` (BeamScribe LiveView UI patterns)

  Covers:
    - Mount renders workspace with correct page_title and three-column layout
    - Status bar renders model/tokens/session id
    - Empty message does not append to list
    - Send message adds user message, clears input, sets running state
    - handle_info %AgentEvent{} struct consumes events correctly
    - :message_delta incrementally merges into last assistant message
    - :tool_start / :tool_end display tool progress with input/duration/errors
    - :run_start / :run_end manage running state and status
    - File preview empty state and error state
    - Diff rendering with basic +/- highlights
    - Both {:agent_event, event} and bare %AgentEvent{} dispatch work
    - Tool event helpers: summarize_input, format_duration, update_tool_event
  """

  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, except: [live: 2]
  import ExUnit.CaptureLog

  alias Handbean.PubSub.AgentEvent

  defmodule CleanupProvider do
    @behaviour Handbean.Agent.Provider

    def complete(_messages, _tools, config) do
      send(config.notify, {:cleanup_provider_waiting, self()})

      receive do
        :finish -> {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
      end
    end

    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  defmodule FileManagerStub do
    def available?, do: true
    def kind, do: :finder

    def reveal(path) do
      send(Application.fetch_env!(:handbean, :file_manager_test_owner), {:revealed, path})
      :ok
    end
  end

  setup do
    {:ok, tracker} = Agent.start(fn -> %{views: MapSet.new(), homes: []} end)
    Process.put(:workspace_live_test_tracker, tracker)
    original_home = System.get_env("HOME")
    original_workspace = System.get_env("HANDBEAN_WORKSPACE")
    original_workspaces_file = System.get_env("HANDBEAN_WORKSPACES_FILE")

    original_config =
      Map.new([:host, :workspaces_file, :workspace_root, :conversation_artifact_root], fn key ->
        {key, Application.fetch_env(:handbean, key)}
      end)

    on_exit(fn ->
      stop_test_runtime!(tracker)

      tracker
      |> Agent.get(& &1.homes)
      |> Enum.each(fn home_dir ->
        if File.exists?(home_dir), do: File.rm_rf!(home_dir)
      end)

      if original_home,
        do: System.put_env("HOME", original_home),
        else: System.delete_env("HOME")

      if original_workspace,
        do: System.put_env("HANDBEAN_WORKSPACE", original_workspace),
        else: System.delete_env("HANDBEAN_WORKSPACE")

      if original_workspaces_file,
        do: System.put_env("HANDBEAN_WORKSPACES_FILE", original_workspaces_file),
        else: System.delete_env("HANDBEAN_WORKSPACES_FILE")

      Enum.each(original_config, fn
        {key, {:ok, value}} -> Application.put_env(:handbean, key, value)
        {key, :error} -> Application.delete_env(:handbean, key)
      end)

      Agent.stop(tracker)
    end)

    isolate_conversation_home!()
    :ok
  end

  defp live(conn, path) do
    result = Phoenix.LiveViewTest.live(conn, path)

    case result do
      {:ok, view, _html} ->
        {_, _, proxy_pid} = view.proxy

        Agent.update(Process.get(:workspace_live_test_tracker), fn state ->
          update_in(state.views, &MapSet.put(&1, {proxy_pid, view.pid}))
        end)

      _other ->
        :ok
    end

    result
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp init_git_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Handbean Test"])
    File.write!(Path.join(path, "README.md"), "main")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "fixture"])
  end

  # ── Helper: build an AgentEvent for tests ──
  defp send_recorded_edit(view, tool_use_id, file_path, change) do
    send(
      view.pid,
      {:agent_event,
       agent_event(:tool_start, %{
         tool_use_id: tool_use_id,
         tool: "edit",
         input: %{file_path: file_path}
       })}
    )

    send(
      view.pid,
      {:agent_event,
       agent_event(
         :tool_end,
         %{
           tool_use_id: tool_use_id,
           tool: "edit",
           duration_ms: 42,
           details:
             %{
               file_path: file_path,
               diff_lines: change.diff_lines
             }
             |> Map.merge(change_event_details(change))
         },
         2
       )}
    )
  end

  defp change_event_details(change) do
    Handbean.ChangeSnapshot.result_details(change, %{
      conversation_id: "workspace-live-revert-test"
    })
  end

  defp agent_event(kind, payload, seq \\ 1) do
    agent_event(kind, payload, seq, "s:1")
  end

  defp agent_event(kind, payload, seq, topic) do
    %AgentEvent{
      kind: kind,
      payload: payload,
      seq: seq,
      topic: topic,
      ts_ms: 0
    }
  end

  defp session_id_from_html(html) do
    ids =
      Regex.scan(~r/data-session-id="([^"]*)"/, html, capture: :all_but_first)
      |> List.flatten()

    Enum.find(ids, &(&1 != "")) || List.last(ids) ||
      raise "no data-session-id in html"
  end

  defp choose_new_conversation_project(view, workspace_id) do
    view
    |> element("#new-conversation-picker-toggle")
    |> render_click()

    view
    |> element("#new-conversation-project-#{workspace_id}")
    |> render_click()
  end

  defp create_default_conversation(view) do
    choose_new_conversation_project(view, "default")

    view |> render() |> session_id_from_html()
  end

  defp isolate_conversation_home! do
    home_dir = Path.join(System.tmp_dir!(), "sigil_lv_home_#{System.unique_integer([:positive])}")
    System.put_env("HOME", home_dir)
    System.delete_env("HANDBEAN_WORKSPACE")
    System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(home_dir, ".handbean/workspaces.json"))
    Application.put_env(:handbean, :host, %{data_dir: home_dir})

    Application.put_env(
      :handbean,
      :workspaces_file,
      Path.join(home_dir, ".handbean/workspaces.json")
    )

    Application.put_env(:handbean, :workspace_root, Handbean.Workspace.default_root())

    Application.put_env(
      :handbean,
      :conversation_artifact_root,
      Path.join(home_dir, ".handbean/conversation-artifacts")
    )

    safe_rm_test_rune!(home_dir)
    assert {:ok, _default_workspace} = Handbean.WorkspaceStore.ensure_default!()

    Agent.update(Process.get(:workspace_live_test_tracker), fn state ->
      %{state | homes: [home_dir | state.homes]}
    end)

    home_dir
  end

  defp stop_test_runtime!(tracker) do
    views = Agent.get(tracker, & &1.views)
    view_pids = MapSet.new(views, &elem(&1, 1))

    views
    |> Enum.each(fn {proxy, view_pid} ->
      stop_and_wait(proxy, fn -> Phoenix.LiveViewTest.ClientProxy.stop(proxy, :shutdown) end)
      stop_and_wait(view_pid, fn -> Process.exit(view_pid, :shutdown) end)
    end)

    Registry.select(Handbean.AgentRunSupervisorRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&is_binary/1)
    |> Enum.each(fn conversation_id ->
      case Registry.lookup(Handbean.AgentRunSupervisorRegistry, conversation_id) do
        [{pid, _}] ->
          stop_and_wait(pid, fn -> Handbean.AgentRunSupervisor.stop_run(conversation_id) end)

        [] ->
          :ok
      end
    end)

    # Runner's async_nolink tasks belong to a different supervisor, not to
    # RunSupervisor or the LiveView ancestry. They can outlive both owners.
    Task.Supervisor.children(Handbean.AgentRunTaskSupervisor)
    |> Enum.each(fn pid ->
      stop_and_wait(pid, fn ->
        Task.Supervisor.terminate_child(Handbean.AgentRunTaskSupervisor, pid)
      end)
    end)

    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          dictionary
          |> Keyword.get(:"$ancestors", [])
          |> Enum.any?(&MapSet.member?(view_pids, &1))

        nil ->
          false
      end
    end)
    |> Enum.each(&wait_for_process/1)

    # Stopping producers does not drain their cast/PubSub consumers. In order,
    # Session forwards lifecycle events and TaskTracker reads conversation metadata.
    Registry.select(Handbean.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.each(fn id ->
      Handbean.PubSub.Session.snapshot(id)
      :ok = Handbean.SessionSupervisor.stop_session(id)
    end)

    GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)
    Handbean.Runtime.TaskTracker.reset()
  end

  test "stopping a run tears down its run-local provider task before runtime cleanup" do
    {:ok, conversation} = Handbean.ConversationStore.create("default")
    id = conversation["id"]

    assert {:ok, %{action: :started}} =
             Handbean.Agent.Coordinator.add_message(id, "hold",
               provider: CleanupProvider,
               provider_config: %{notify: self()},
               model: "cleanup-fixture",
               workspace_path: File.cwd!(),
               source: :cli,
               streaming: false,
               tools: []
             )

    assert_receive {:cleanup_provider_waiting, task}, 1_000
    ref = Process.monitor(task)
    :ok = Handbean.AgentRunSupervisor.stop_run(id)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    :ok = stop_test_runtime!(Process.get(:workspace_live_test_tracker))
  end

  test "cleanup waits for queued lifecycle consumers before removing their HOME" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Cleanup barrier")
    id = conversation["id"]
    {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: id)
    consumer = Process.whereis(Handbean.Runtime.TaskTracker)
    tracker = Process.get(:workspace_live_test_tracker)
    :ok = :sys.suspend(consumer)
    :erlang.trace(consumer, true, [:receive])

    try do
      Handbean.PubSub.Session.broadcast_event(id, :run_start, %{run_id: "cleanup-barrier"})
      Handbean.PubSub.Session.snapshot(id)
      cleanup = Task.async(fn -> stop_test_runtime!(tracker) end)

      # The ordinary call is queued behind lifecycle work. A system get_state
      # call would be served while suspended and would not provide this barrier.
      assert_receive {:trace, ^consumer, :receive, {:"$gen_call", _, :snapshot}}, 1_000
      ref = cleanup.ref
      refute_received {^ref, _}
      :ok = :sys.resume(consumer)
      assert :ok = Task.await(cleanup)

      File.rm_rf!(System.get_env("HOME"))
      GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)

      refute File.exists?(System.get_env("HOME"))
    after
      :erlang.trace(consumer, false, [:receive])
      :sys.resume(consumer)
    end
  end

  test "cleanup tolerates a process exiting between the liveness check and stop call" do
    {:ok, pid} = Agent.start(fn -> :waiting end)

    stop_and_wait(pid, fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      GenServer.stop(pid)
    end)

    refute Process.alive?(pid)
  end

  defp stop_and_wait(pid, stop) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      try do
        _ = stop.()
      catch
        :exit, {:noproc, _} -> :ok
      end

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end
  end

  defp wait_for_process(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  defp safe_rm_test_rune!(home_dir) do
    target = Path.expand(Path.join(home_dir, ".handbean"))
    tmp_root = Path.expand(System.tmp_dir!())

    if String.starts_with?(target, tmp_root) do
      File.rm_rf!(target)
    else
      raise "[PathSafety] refusing to delete non-temp .handbean/: #{target} (tmp_root=#{tmp_root})"
    end
  end

  defp write_test_models_config(path) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "provider" => "stepfun",
            "models" => [
              %{
                "id" => "step-router-v1",
                "name" => "Step Router v1 (StepFun)",
                "reasoning" => true,
                "defaultReasoning" => "medium",
                "thinkingLevelMap" => %{"minimal" => "low", "xhigh" => nil}
              }
            ]
          },
          "sui2api" => %{
            "baseUrl" => "https://example.test/v1",
            "api" => "openai-responses",
            "models" => [
              %{"id" => "gpt-5.5", "name" => "GPT-5.5"}
            ]
          }
        }
      })
    )
  end

  defp configure_test_models! do
    models_path =
      Path.join(
        System.tmp_dir!(),
        "sigil_lv_models_#{System.unique_integer([:positive])}.json"
      )

    write_test_models_config(models_path)
    System.put_env("HANDBEAN_MODELS_FILE", models_path)

    on_exit(fn ->
      System.delete_env("HANDBEAN_MODELS_FILE")
      if File.exists?(models_path), do: File.rm!(models_path)
    end)

    models_path
  end

  describe "mount" do
    test "renders workspace with correct page_title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Handbean — Workspace"
      assert html =~ "projects-panel-title"
      assert html =~ "专案" or html =~ "Projects"
    end

    test "renders three-column layout regions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"activity-bar\""
      assert html =~ "id=\"workspace-panel\""
      assert html =~ "id=\"ai-panel\""
    end

    test "renders status bar with tokens and session id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"status-bar\""
      refute html =~ "id=\"status-model\""
      refute html =~ "href=\"?locale="
      assert html =~ "Tokens:"
      assert html =~ "id=\"status-input-tokens\""
      assert html =~ "id=\"status-output-tokens\""
      assert html =~ "id=\"status-label\""
      assert html =~ "idle"
      assert html =~ "sid:"
    end

    test "loads persisted token usage for an existing conversation", %{conn: conn} do
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Token Stats")

      :ok =
        Handbean.ConversationStore.add_token_usage(conversation["id"], %{
          input_tokens: 17,
          output_tokens: 23
        })

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert has_element?(view, "#status-input-tokens", "17")
      assert has_element?(view, "#status-output-tokens", "23")
    end

    test "does not select a conversation owned by another workspace", %{conn: conn} do
      {:ok, foreign_conversation} =
        Handbean.ConversationStore.create("another-workspace", title: "Foreign")

      {:ok, _view, html} = live(conn, "/w/default/c/#{foreign_conversation["id"]}")

      refute html =~ ~s(data-session-id="#{foreign_conversation["id"]}")
    end

    test "does not render archived conversations in the sidebar", %{conn: conn} do
      {:ok, conversation} =
        Handbean.ConversationStore.create("default", title: "Archived conversation")

      {:ok, _archived} = Handbean.ConversationStore.archive(conversation["id"])

      {:ok, _view, html} = live(conn, "/")

      refute html =~ ~s(data-conversation-id="#{conversation["id"]}")
    end

    test "static mount shows loading state and connected mount fills the sidebar", %{conn: conn} do
      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          title: "Loaded asynchronously",
          timeline: [%{"id" => "message", "role" => "user", "content" => "hello"}]
        )

      static_html = conn |> get("/") |> html_response(200)
      assert static_html =~ ~s(id="conversation-list-loading")
      refute static_html =~ "Loaded asynchronously"

      {:ok, view, _html} = live(recycle(conn), "/")
      rendered = render_async(view, 5_000)

      assert rendered =~ "Loaded asynchronously"
      assert rendered =~ ~s(data-conversation-id="#{conversation["id"]}")
      refute rendered =~ ~s(id="conversation-list-loading")
      refute rendered =~ ~s(id="conversation-list-refreshing")
    end

    test "sidebar More reveals the next conversation batch", %{conn: conn} do
      for index <- 1..12 do
        {:ok, _conversation} =
          Handbean.ConversationStore.create("default", title: "History #{index}")
      end

      {:ok, view, _html} = live(conn, "/")
      render_async(view, 5_000)

      assert has_element?(view, "#workspace-more-default")

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#workspace-conversations-default > .conversation-row")
             |> length() == 10

      view
      |> element("#workspace-more-default")
      |> render_click()

      refute has_element?(view, "#workspace-more-default")

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("#workspace-conversations-default > .conversation-row")
             |> length() == 12
    end

    test "stale sidebar results and refresh failures preserve newer rows" do
      current = %{"id" => "current", "title" => "Current", "workspace_id" => "default"}
      stale = %{"id" => "stale", "title" => "Stale", "workspace_id" => "default"}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          conversation_list_boot: nil,
          conversation_list_error: nil,
          conversation_list_loaded: true,
          conversation_list_loading: true,
          conversation_list_revision: 2,
          conversation_list_task_revision: 1,
          conversations_by_workspace: %{"default" => [current], free: []},
          workspaces: [%{"id" => "default", "path" => System.tmp_dir!()}]
        }
      }

      assert {:noreply, refreshed} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 :conversation_list,
                 {:ok, {1, {:ok, %{"default" => [stale], free: []}}}},
                 socket
               )

      assert refreshed.assigns.conversation_list_revision == 3
      assert refreshed.assigns.conversation_list_task_revision == 3
      assert refreshed.assigns.conversations_by_workspace["default"] == [current]

      assert {:noreply, failed} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 :conversation_list,
                 {:exit, :index_unavailable},
                 refreshed
               )

      assert failed.assigns.conversations_by_workspace["default"] == [current]
      assert failed.assigns.conversation_list_loaded
      refute failed.assigns.conversation_list_loading
      assert failed.assigns.conversation_list_error
    end

    test "stale sidebar task exits trigger a fresh query without showing an error" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          conversation_list_error: nil,
          conversation_list_loaded: true,
          conversation_list_loading: true,
          conversation_list_revision: 2,
          conversation_list_task_revision: 1,
          conversations_by_workspace: %{"default" => [], free: []},
          workspaces: [%{"id" => "default", "path" => System.tmp_dir!()}]
        }
      }

      assert {:noreply, refreshed} =
               HandbeanWeb.WorkspaceLive.handle_async(
                 :conversation_list,
                 {:exit, :index_unavailable},
                 socket
               )

      assert refreshed.assigns.conversation_list_revision == 3
      assert refreshed.assigns.conversation_list_task_revision == 3
      assert refreshed.assigns.conversation_list_loading
      refute refreshed.assigns.conversation_list_error
    end

    test "renders AI input area with input box and send button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"ai-input\""
      assert html =~ "id=\"send-button\""
      assert html =~ "id=\"ai-input-area\""
    end

    test "ai input textarea does not render leading whitespace around the value", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~r/<textarea[^>]*id=\"ai-input\"[^>]*><\/textarea>/
      refute html =~ ~r/<textarea[^>]*id=\"ai-input\"[^>]*>\s+\n\s*<\/textarea>/
    end

    test "model picker distinguishes stored variants that share a display name" do
      models = [
        %{id: "cursor/composer-2.5", model_id: "composer-2.5", name: "Composer 2.5"},
        %{id: "cursor/composer-2.5-fast", model_id: "composer-2.5-fast", name: "Composer 2.5"},
        %{
          id: "cursor/grok-4.7-high-fast",
          model_id: "grok-4.7-high-fast",
          name: "Grok 4.7 High Fast"
        }
      ]

      assert HandbeanWeb.WorkspaceLive.model_option_label(Enum.at(models, 0), models) ==
               "Composer 2.5"

      assert HandbeanWeb.WorkspaceLive.model_option_label(Enum.at(models, 1), models) ==
               "Composer 2.5 Fast"

      assert HandbeanWeb.WorkspaceLive.model_option_label(Enum.at(models, 2), models) ==
               "Grok 4.7 High Fast"
    end

    test "renders empty state when no messages are present", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"no-messages\""
      assert html =~ "No messages yet"
    end

    test "renders the workspace file tree instead of an empty editor placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-file-tree[role='tree']")
      refute has_element?(view, "#editor-content")
    end

    test "diff view is hidden initially", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "id=\"diff-view\""
      refute html =~ "file-change-diff"
    end

    test "workspace panel starts in the Files view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-tab.active", "Files")
      refute has_element?(view, "#terminal-panel")
    end
  end

  describe "input interaction" do
    test "update_input event updates the input_value assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      _html = render_keyup(view, "update_input", %{"value" => "hello world"})

      assert element(view, "textarea#ai-input") |> render() =~ "hello world"
    end

    test "empty message does not add to list on send (whitespace only)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_submit(%{"message" => "   "})

      # No new user message with whitespace-only content should appear
      refute render(view) =~ ~s(class="msg-bubble msg-user")
    end

    test "empty string does not add to list on send", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_submit(%{"message" => ""})

      refute render(view) =~ ~s(class="msg-bubble msg-user")
    end
  end

  describe "auto title sidebar" do
    test "a generated title replaces New chat without a reload", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-title-delay",
          title: "New chat",
          title_source: "manual",
          timeline: [
            %{
              "id" => "title-user-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "模型列表怎么不一致"
            }
          ]
        )

      {:ok, view, html} = live(conn, "/")
      assert html =~ "New chat"

      send(view.pid, {:conversation_title_ready, conversation["id"], "模型列表展示不一致"})

      assert has_element?(view, "#conversation-conv-title-delay", "模型列表展示不一致")
      refute has_element?(view, "#conversation-conv-title-delay", "New chat")
    end

    test "a provisional title replaces New chat before the model returns", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-title-now",
          title: "New chat",
          title_source: "manual"
        )

      {:ok, view, html} = live(conn, "/")
      assert html =~ "New chat"

      assert {:ok, "模型列表怎么不一致"} =
               Handbean.ConversationTitleGenerator.publish_provisional(
                 conversation["id"],
                 "模型列表怎么不一致"
               )

      assert has_element?(view, "#conversation-conv-title-now", "模型列表怎么不一致")
      refute has_element?(view, "#conversation-conv-title-now", "New chat")
    end
  end

  describe "send_message" do
    test "adding a user message appears in the message list", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Read sample.txt"})
        assert render(view) =~ "Read sample.txt"
      end)
    end

    test "input clears after sending a message", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Read config"})
        assert has_element?(view, "textarea#ai-input", "")
      end)
    end

    test "send button prevents duplicate submission while the server acknowledges", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#send-button[phx-disable-with='…']")
    end

    test "sending a message persists user-visible history before run_end", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)
      view |> element("form") |> render_submit(%{"message" => "durable before run_end"})
      _ = render(view)

      assert Enum.any?(
               Handbean.ConversationStore.load_messages(conversation_id),
               &match?(%{"content" => "durable before run_end", "role" => "user"}, &1)
             )

      {:ok, _view2, html2} = live(conn, "/")
      assert html2 =~ "durable before run_end"

      assert {:ok, conversation} = Handbean.ConversationStore.get(conversation_id)

      assert Enum.any?(conversation["timeline"], fn entry ->
               entry["content"] == "durable before run_end"
             end)
    end

    test "sending a message preserves previously loaded history", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, _conv} =
        Handbean.ConversationStore.create("default",
          id: "conv-history",
          title: "New chat",
          timeline: [
            %{
              "id" => "timeline-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "Earlier context"
            },
            %{
              "id" => "timeline-2",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "Previous reply"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/")

      rendered_before = render(view)
      assert rendered_before =~ "Earlier context"
      assert rendered_before =~ "Previous reply"

      view |> element("form") |> render_submit(%{"message" => "New question"})

      rendered_after = render(view)
      assert rendered_after =~ "Earlier context"
      assert rendered_after =~ "Previous reply"
      assert rendered_after =~ "New question"
    end

    test "renders role-neutral user and assistant attachments without an empty assistant bubble",
         %{
           conn: conn
         } do
      conversation_id = "conv-assistant-media"
      media_url = "/media/#{conversation_id}/media-generated/content"
      data_url = "data:image/png;base64,iVBORw0KGgo="

      assistant_attachments = [
        %{
          "media_id" => "media-generated",
          "conversation_id" => conversation_id,
          "kind" => "image",
          "mime_type" => "image/png",
          "filename" => "generated.png"
        },
        %{
          "kind" => "image",
          "mime_type" => "image/png",
          "filename" => "legacy-data.png",
          "data" => "iVBORw0KGgo="
        },
        %{
          "kind" => "text",
          "filename" => "notes.txt",
          "url" => "/uploads/legacy-notes.txt"
        }
      ]

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: conversation_id,
          title: "Assistant media",
          timeline: [
            %{
              "id" => "user-legacy-media",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "",
              "attachments" => [
                %{
                  "kind" => "image",
                  "filename" => "legacy-user.png",
                  "url" => "/uploads/legacy-user.png"
                }
              ]
            },
            %{
              "id" => "assistant-media",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "",
              "attachments" => assistant_attachments
            },
            %{
              "id" => "assistant-text",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "Rendered reply"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        timeline =
          Enum.map(socket.assigns.timeline, fn
            %{"id" => "assistant-media"} = entry ->
              Map.put(entry, "attachments", assistant_attachments)

            entry ->
              entry
          end)

        socket =
          socket
          |> Phoenix.Component.assign(:timeline, timeline)
          |> Phoenix.LiveView.stream(:timeline, timeline, reset: true)

        %{state | socket: socket}
      end)

      render_click(view, "clear_composer_error", %{})

      assert has_element?(
               view,
               "[data-user-msg='user-legacy-media'] .msg-shot[data-shot-src='/uploads/legacy-user.png'] img[alt='legacy-user.png']"
             )

      assert has_element?(view, "[data-assistant-msg='assistant-media']")

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] .msg-shot[data-shot-name='generated.png'][title='generated.png'][aria-label] img[alt='generated.png']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] .msg-shot[data-shot-src='#{media_url}'] img[src='#{media_url}']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] .msg-shot[data-shot-src='#{data_url}'] img[src='#{data_url}'][alt='legacy-data.png']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-media'] a.msg-file[href='/uploads/legacy-notes.txt'][target='_blank'][rel='noreferrer']",
               "notes.txt"
             )

      refute has_element?(view, "[data-assistant-msg='assistant-media'] .msg-bubble")
      refute has_element?(view, "[data-assistant-msg='assistant-media'] .msg-copy-btn")

      refute has_element?(
               view,
               "[data-assistant-msg='assistant-media'] [phx-hook='StreamingMarkdown']"
             )

      assert has_element?(
               view,
               "[data-assistant-msg='assistant-text'] [phx-hook='StreamingMarkdown']"
             )

      assert has_element?(view, "[data-assistant-msg='assistant-text'] .msg-copy-btn")

      assert {:ok, transcript} =
               Handbean.ConversationTranscriptStore.list(conversation["id"])

      persisted = Enum.find(transcript, &(&1["id"] == "assistant-media"))
      media_descriptor = hd(persisted["attachments"])
      assert media_descriptor["media_id"] == "media-generated"
      refute Map.has_key?(media_descriptor, "url")
    end

    test "pages long history backward without losing newly appended messages", %{conn: conn} do
      timeline =
        for index <- 1..250 do
          %{
            "id" => "long-history-#{index}",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "history item #{index}"
          }
        end

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-long-history",
          title: "Long history",
          timeline: timeline
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert render(view) =~ "history item 250"
      refute render(view) =~ "history item 150"
      assert has_element?(view, "#ai-messages[data-history-has-more='true']")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :message_delta,
           %{chunk: "live after newest page"},
           1,
           "session:#{conversation["id"]}"
         )}
      )

      render_hook(view, "load_older_history", %{})
      rendered = render(view)
      assert rendered =~ "history item 51"
      assert rendered =~ "live after newest page"

      render_hook(view, "load_older_history", %{})
      rendered = render(view)
      assert rendered =~ "history item 1"
      assert rendered =~ "live after newest page"
      refute has_element?(view, "#ai-messages[data-history-has-more='true']")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :message_delta,
           %{chunk: " and after loading older history"},
           2,
           "session:#{conversation["id"]}"
         )}
      )

      rendered = render(view)
      assert rendered =~ "live after newest page and after loading older history"
      assert rendered =~ "history item 1"
    end

    test "projects tool groups when older history is loaded", %{conn: conn} do
      older_entries = [
        %{
          "id" => "older-commentary",
          "content_type" => "assistant_msg",
          "role" => "assistant",
          "content" => "Inspecting older files"
        },
        %{
          "id" => "older-read",
          "content_type" => "tool",
          "tool_name" => "read",
          "tool_status" => "done",
          "input" => %{"file_path" => "lib/older.ex"}
        },
        %{
          "id" => "older-search",
          "content_type" => "tool",
          "tool_name" => "grep",
          "tool_status" => "done",
          "input" => %{"path" => "lib", "pattern" => "older"}
        },
        %{
          "id" => "older-answer",
          "content_type" => "assistant_msg",
          "role" => "assistant",
          "content" => "Older inspection complete"
        }
      ]

      newer_entries =
        Enum.map(1..100, fn index ->
          %{
            "id" => "newer-history-#{index}",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "newer history item #{index}"
          }
        end)

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-older-tool-work",
          title: "Older tool work",
          timeline: older_entries ++ newer_entries
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      refute has_element?(view, "#older-read")

      render_hook(view, "load_older_history", %{})

      assert has_element?(view, "#older-read .tool-work-collapsed.tool-work-lead")

      assert has_element?(
               view,
               "#tool-work-summary-older-read[aria-expanded='false']",
               "Explored 1 file, 1 search"
             )

      assert has_element?(view, "#older-search .tool-work-collapsed.tool-work-follow")
      refute has_element?(view, "#tool-work-line-older-read")
      refute has_element?(view, "#tool-work-line-older-search")
    end

    test "switching away and back reloads persisted streaming display history", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, first} =
        Handbean.ConversationStore.create("default",
          id: "conv-switch-a",
          title: "Count from 1",
          timeline: [
            %{
              "id" => "msg-user-a",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "从1数到1011"
            }
          ]
        )

      {:ok, second} =
        Handbean.ConversationStore.create("default",
          id: "conv-switch-b",
          title: "Second chat",
          timeline: []
        )

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      assert render(view) =~ "从1数到1011"

      Handbean.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:run_start, %{model: "test"}}
      )

      Handbean.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:message_delta, %{chunk: "1, 2, 3, 4, 5"}}
      )

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      refute render(view) =~ "1, 2, 3, 4, 5"

      Handbean.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:run_end, %{status: "completed", turns: 1}}
      )

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      rendered = render(view)
      assert rendered =~ "从1数到1011"
      assert rendered =~ "1, 2, 3, 4, 5"
    end

    test "syncing current running conversation preserves in-flight timeline", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-running-preserve",
          title: "Running preserve",
          timeline: [
            %{
              "id" => "msg-user-running-preserve",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "keep running user text"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      topic = "session:#{conversation["id"]}"

      # Runtime text is durable before broadcast; recovery intentionally does
      # not preserve an unpersisted projection-only assistant row.
      {:ok, _} =
        Handbean.ConversationTranscriptStore.append(conversation["id"], %{
          "id" => "running-reply",
          "role" => "assistant",
          "content_type" => "assistant_msg",
          "content" => "in-flight reply",
          "status" => "streaming"
        })

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, topic)})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :message_delta,
           %{transcript_id: "running-reply", text_offset: 0, text: "in-flight reply"},
           2,
           topic
         )}
      )

      assert render(view) =~ "in-flight reply"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{conversation["id"]}']"
      )
      |> render_click()

      assert render(view) =~ "in-flight reply"
    end

    test "switching conversations ignores previous conversation running state when resetting timeline",
         %{
           conn: conn
         } do
      isolate_conversation_home!()

      {:ok, first} =
        Handbean.ConversationStore.create("default",
          id: "conv-running-switch-a",
          title: "Running first",
          timeline: [
            %{
              "id" => "msg-user-running-a",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "first running conversation"
            }
          ]
        )

      {:ok, second} =
        Handbean.ConversationStore.create("default",
          id: "conv-running-switch-b",
          title: "Running second",
          timeline: [
            %{
              "id" => "msg-user-running-b",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "second selected conversation"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{first["id"]}")
      first_topic = "session:#{first["id"]}"

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, first_topic)})

      assert render(view) =~ "first running conversation"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      rendered = render(view)
      assert rendered =~ "second selected conversation"
      refute rendered =~ "first running conversation"
      refute has_element?(view, "#status-label", "running")
    end

    test "switching conversations clears composer attachments from the previous conversation", %{
      conn: conn
    } do
      isolate_conversation_home!()

      {:ok, first} =
        Handbean.ConversationStore.create("default",
          id: "conv-attach-switch-a",
          title: "Attach first"
        )

      {:ok, second} =
        Handbean.ConversationStore.create("default",
          id: "conv-attach-switch-b",
          title: "Attach second"
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{first["id"]}")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{
            path: png_path,
            name: "from-a.png",
            type: "image/png",
            content: File.read!(png_path)
          }
        ])

      render_upload(upload, "from-a.png")
      assert has_element?(view, "#composer-attachments span.sr-only", "from-a.png")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      refute has_element?(view, "#composer-attachments span.sr-only", "from-a.png")
      refute has_element?(view, "#composer-attachments button[phx-click='cancel_upload']")
      assert :sys.get_state(view.pid).socket.assigns.pending_attachments == []

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#composer-attachments img[alt='from-a.png']")
      assert :sys.get_state(view.pid).socket.assigns.current_conversation_id == first["id"]
    end

    test "sets running state after submitting a message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Use run_start event to reliably set running state (avoids race with async Task)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      rendered = render(view)
      assert rendered =~ "running"
    end

    test "input remains enabled when agent is running for steering", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Use run_start event to reliably set running state (avoids race with async Task)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      rendered = render(view)
      refute rendered =~ "disabled"
    end

    test "tool_events remain visible on new message send", %{conn: conn} do
      configure_test_models!()

      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        sid = create_default_conversation(view)
        {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
        {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
        :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
        topic = "session:#{sid}"

        send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, topic)})

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{tool: "read", input: %{file_path: "test.txt"}},
             2,
             topic
           )}
        )

        send(
          view.pid,
          {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 25}, 3, topic)}
        )

        assert has_element?(view, "#tool-event-read")
        send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed"}, 4, topic)})

        view
        |> element("form")
        |> render_submit(%{"message" => "New message", "model" => "stepfun/step-router-v1"})

        assert has_element?(view, "#tool-event-read")
        assert render(view) =~ "New message"
      end)
    end

    test "running submit enqueues candidate instead of clearing active tool state", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.txt"}}, 2, topic)}
      )

      assert has_element?(view, "#tool-event-read")

      view
      |> element("form")
      |> render_submit(%{"message" => "please adjust", "model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#tool-event-read")
      assert render(view) =~ "please adjust"

      assert [%Handbean.Agent.Message{role: :user, content: "please adjust"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)

      assert [] = Handbean.Agent.CandidateQueue.drain_follow_up(queue)
    end

    test "running queue button enqueues follow_up", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("#queue-button")
      |> render_click(%{
        "message" => "when finished",
        "model" => "stepfun/step-router-v1"
      })

      assert render(view) =~ "when finished"
      assert render(view) =~ "Queued"

      assert [%Handbean.Agent.Message{role: :user, content: "when finished"}] =
               Handbean.Agent.CandidateQueue.drain_follow_up(queue)

      assert [] = Handbean.Agent.CandidateQueue.drain_steer(queue)
    end

    test "idle queue_message starts a new run instead of erroring", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      _sid = create_default_conversation(view)

      render_click(view, "queue_message", %{
        "message" => "idle queue becomes a run",
        "model" => "stepfun/step-router-v1"
      })

      html = render(view)
      assert html =~ "idle queue becomes a run"
      refute html =~ "no longer accepting"
    end

    test "running submit records pending, undo restores draft, terminal run_end marks undelivered",
         %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("form")
      |> render_submit(%{"message" => "steer pending", "model" => "stepfun/step-router-v1"})

      assert render(view) =~ "Waiting to insert"
      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [msg_id] = Map.keys(pending)

      view
      |> element("button[phx-click='cancel_pending']")
      |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.input_value =~ "steer pending"
      assert Handbean.Agent.CandidateQueue.get_messages(queue) == []

      view
      |> element("form")
      |> render_submit(%{"message" => "left behind", "model" => "stepfun/step-router-v1"})

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_end, %{status: "cancelled"})
      # Wait for the asynchronous terminal event before checking its rendered result.
      _snapshot = Handbean.PubSub.Session.snapshot(sid)

      html = render(view)
      assert html =~ "Not delivered"

      _ = msg_id
    end

    test "resend_pending keeps composer draft and pending attachments, and ignores a second click",
         %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("form")
      |> render_submit(%{"message" => "retry later", "model" => "stepfun/step-router-v1"})

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_end, %{status: "cancelled"})

      assert render(view) =~ "Not delivered"
      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [old_id] = Map.keys(pending)

      render_keyup(view, "update_input", %{"value" => "keep draft"})

      keep_att = %{"id" => "keep-web", "filename" => "keep.png"}

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{state | socket: Phoenix.Component.assign(socket, :pending_attachments, [keep_att])}
      end)

      view
      |> element("button[phx-click='resend_pending']")
      |> render_click(%{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "keep draft"
      assert assigns.pending_attachments == [keep_att]
      refute Map.has_key?(assigns.pending_messages, old_id)

      queued = Handbean.Agent.CandidateQueue.get_messages(queue)
      assert Enum.any?(queued, &(&1.message.content == "retry later"))
      queue_count = length(queued)

      render_click(view, "resend_pending", %{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "keep draft"
      assert length(Handbean.Agent.CandidateQueue.get_messages(queue)) == queue_count
    end

    test "resend_pending keeps the undelivered item when send fails", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("form")
      |> render_submit(%{"message" => "cannot resend", "model" => "stepfun/step-router-v1"})

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_end, %{status: "cancelled"})

      assert render(view) =~ "Not delivered"
      [old_id] = Map.keys(:sys.get_state(view.pid).socket.assigns.pending_messages)

      too_many =
        for i <- 1..5 do
          %{"id" => "att-#{i}", "filename" => "#{i}.png"}
        end

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        pending = socket.assigns.pending_messages

        pending =
          Map.update!(pending, old_id, fn item ->
            Map.put(item, :attachments, too_many)
          end)

        %{state | socket: Phoenix.Component.assign(socket, :pending_messages, pending)}
      end)

      :ok = Handbean.PubSub.Session.broadcast_event(sid, :run_start, %{model: "step-router-v1"})

      view
      |> element("button[phx-click='resend_pending']")
      |> render_click(%{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.pending_messages[old_id].status == :undelivered
      assert assigns.composer_error == "At most 4 attachments per message."
    end

    test "reload hydrates queued attachments from transcript and undo restores them", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      mid = "msg-hyd-#{System.unique_integer([:positive])}"
      atts = [%{"id" => "att-w", "filename" => "pic.png", "kind" => "image"}]

      {:ok, _} =
        Handbean.ConversationTranscriptStore.append(sid, %{
          "id" => mid,
          "role" => "user",
          "content_type" => "user_msg",
          "content" => "with picture",
          "attachments" => atts
        })

      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbean.PubSub.Session.enqueue_candidate(sid, "with picture", message_id: mid)

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("#conversation-#{sid} button[phx-click='select_conversation']")
      |> render_click()

      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      assert pending[mid].content == "with picture"
      assert hd(pending[mid].attachments)["id"] == "att-w"
      assert hd(pending[mid].attachments)["filename"] == "pic.png"

      view
      |> element("button[phx-click='cancel_pending']")
      |> render_click(%{"id" => mid})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value =~ "with picture"
      assert Enum.any?(assigns.pending_attachments, &(&1["filename"] == "pic.png"))
      assert Handbean.Agent.CandidateQueue.get_messages(queue) == []
    end

    test "running steer button click enqueues candidate", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      assert has_element?(view, "#status-label", "running")

      view
      |> element("form")
      |> render_submit(%{
        "message" => "please adjust by click",
        "model" => "stepfun/step-router-v1"
      })

      assert render(view) =~ "please adjust by click"

      assert [%Handbean.Agent.Message{role: :user, content: "please adjust by click"}] =
               Handbean.Agent.CandidateQueue.drain_steer(queue)
    end

    test "UI running with idle coordinator starts a new run instead of stale error", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-stale-running",
          title: "Stale running"
        )

      sid = conversation["id"]

      on_exit(fn ->
        _ = Handbean.Agent.Coordinator.cancel(sid)

        case Registry.lookup(Handbean.AgentRunRegistry, sid) do
          [{pid, _value}] ->
            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

          [] ->
            :ok
        end
      end)

      {:ok, view, _html} = live(conn, "/w/default/c/#{sid}")
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      assert has_element?(view, "#status-label", "running")

      view
      |> element("form")
      |> render_submit(%{"message" => "start again", "model" => "stepfun/step-router-v1"})

      rendered = render(view)
      refute rendered =~ "The previous run is no longer accepting input"
      assert rendered =~ "start again"

      assert Enum.any?(
               Handbean.ConversationStore.load_messages(sid),
               &(&1["content"] == "start again")
             )
    end

    test "turn_start restores working indicator when a later provider turn is active", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:message_delta, %{chunk: "working"}, 2, topic)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "completed"}, 3, topic)}
      )

      refute has_element?(view, "#agent-working")

      send(
        view.pid,
        {:agent_event, agent_event(:turn_start, %{turn: 8}, 4, topic)}
      )

      assert has_element?(view, "#agent-working")
      assert has_element?(view, "#status-label", "running")
    end

    test "sending a message with an uploaded image renders attachments in the timeline", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{path: png_path, name: "x.png", type: "image/png", content: File.read!(png_path)}
        ])

      render_upload(upload, "x.png")

      view |> element("form") |> render_submit(%{"message" => "see image"})
      rendered = render(view)

      assert rendered =~ "see image"
      assert rendered =~ "/uploads/"
      assert rendered =~ "msg-shot"
      assert rendered =~ "data-shot-open"
    end

    test "completed uploaded image renders a composer attachment preview before send", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{path: png_path, name: "preview.png", type: "image/png", content: File.read!(png_path)}
        ])

      render_upload(upload, "preview.png")

      assert has_element?(view, "#composer-attachments")
      assert has_element?(view, "#composer-attachments span.sr-only", "preview.png")
      assert has_element?(view, "#composer-attachments button[phx-click='cancel_upload']")
      assert render(view) =~ "preview.png"

      view
      |> element("#composer-attachments button[phx-click='cancel_upload']")
      |> render_click()

      refute has_element?(view, "#composer-attachments span.sr-only", "preview.png")
      refute has_element?(view, "#composer-attachments button[phx-click='cancel_upload']")
    end

    test "pending composer attachment can be removed from the thumbnail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{
          state
          | socket:
              Phoenix.Component.assign(socket, :pending_attachments, [
                %{"id" => "keep-web", "filename" => "keep.png", "url" => "/uploads/keep.png"}
              ])
        }
      end)

      render_click(view, "clear_composer_error", %{})
      assert has_element?(view, "#composer-attachments button[phx-click='remove_attachment']")

      view
      |> element("#composer-attachments button[phx-click='remove_attachment']")
      |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.pending_attachments == []
      refute has_element?(view, "#composer-attachments button[phx-click='remove_attachment']")
    end

    test "sent image uses persistable string-key fields for timeline urls", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{
            path: png_path,
            name: "string-key.png",
            type: "image/png",
            content: File.read!(png_path)
          }
        ])

      render_upload(upload, "string-key.png")
      view |> element("form") |> render_submit(%{"message" => "string keys"})
      html = render(view)
      assert html =~ "string keys"
      assert html =~ "/uploads/"
      assert html =~ "string-key.png" or html =~ "alt="
    end

    test "upload plus button wraps the live file input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".composer-icon-btn input[type='file']")
    end
  end

  describe "agent events via handle_info" do
    test "run_start event sets running state and clears previous tool state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude-sonnet"})})

      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "claude-sonnet"
    end

    test "run_start event via bare struct (no tuple wrapper)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, agent_event(:run_start, %{model: "claude-haiku"}))

      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "claude-haiku"
    end

    test "message_delta appends a new assistant message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Hello, I am"})})

      assert has_element?(view, ".msg-bubble.msg-assistant", "Hello, I am")
    end

    test "ignores tuple-wrapped agent events from a stale session topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      current_sid = view |> render() |> session_id_from_html()
      stale_topic = "session:stale-conversation"

      send(
        view.pid,
        {:agent_event,
         agent_event(:message_delta, %{chunk: "stale assistant text"}, 1, stale_topic)}
      )

      assert is_binary(current_sid)
      refute render(view) =~ "stale assistant text"
    end

    test "ignores bare AgentEvent structs from a stale session topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        agent_event(:message_delta, %{chunk: "bare stale assistant text"}, 1, "session:old-conv")
      )

      refute render(view) =~ "bare stale assistant text"
    end

    test "message_delta merges into last assistant message incrementally", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Part 1. "})})

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Part 2."}, 2)})

      # Should have ONE assistant message with combined content
      html = render(view)
      assert html =~ "Part 1. Part 2."
    end

    test "thinking_delta shows thinking status without exposing content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event, agent_event(:thinking_delta, %{chunk: "private reasoning"}, 2)}
      )

      html = render(view)
      refute html =~ "private reasoning"

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Visible answer"}, 3)})

      html = render(view)
      refute html =~ "private reasoning"
      assert html =~ "Visible answer"
    end

    test "message_delta after user message creates new assistant block", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Hello"})
        send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Hi there!"})})
        assert render(view) =~ "Hello"
        assert render(view) =~ "Hi there!"
      end)
    end

    test "tool_start event displays compact tool verb and input summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_read_1",
           tool: "read",
           input: %{file_path: "config/runtime.exs"}
         })}
      )

      assert has_element?(view, "#tool-tu_read_1")
      assert has_element?(view, "#tool-tu_read_1", "read")
      assert has_element?(view, "#tool-tu_read_1", "runtime.exs")
    end

    test "tool_start event with command input shows command summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "mix test"}})}
      )

      assert has_element?(view, "#tool-event-bash")
      assert has_element?(view, "#tool-event-bash", "$")
      assert has_element?(view, "#tool-event-bash", "mix test")
      assert has_element?(view, "#tool-work-line-tool-event-bash.tool-work-line")
      refute has_element?(view, "#tool-event-bash .tool-status-line")
    end

    test "tool_start event with content input shows content summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "write", input: %{content: "defmodule Foo do end"}})}
      )

      assert has_element?(view, "#tool-event-write")
      assert has_element?(view, "#tool-event-write", "defmodule Foo do end")
    end

    test "tool_start event with empty input shows only the compact verb", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{}})})

      assert has_element?(view, "#tool-event-read")
    end

    test "tool_end event updates tool status to done with duration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.txt"}})}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 250}, 2)})

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "tool-work-collapsed"
    end

    test "schedule center owns one-shot controls and follows the current conversation", %{
      conn: conn
    } do
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Scheduled check")

      {:ok, schedule} =
        Handbean.Schedule.Store.create(%{
          workspace_id: "default",
          conversation_id: conversation["id"],
          name: "检查编译",
          instruction: "汇报编译结果",
          time_zone: "Asia/Shanghai",
          model: "fake/model",
          rule: %{
            "kind" => "once",
            "label" => "一小时后，只一次",
            "at" =>
              Handbean.Schedule.now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
          }
        })

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      card = "#schedule-#{schedule.id}"

      assert has_element?(view, "#activity-bar #schedule-nav")
      refute has_element?(view, ".schedule-launcher")
      refute has_element?(view, "#once-schedule-dock")
      refute has_element?(view, "#schedule-center")

      view |> element("#schedule-nav") |> render_click()

      assert has_element?(view, "#schedule-center #{card}")
      refute has_element?(view, "#ai-input-area")
      refute has_element?(view, "#workspace-panel")
      assert has_element?(view, "#{card} [phx-click='schedule_pause']")

      view |> element("#{card} [phx-click='schedule_pause']") |> render_click()
      assert has_element?(view, "#{card} [phx-click='schedule_resume']")
      assert {:ok, %{status: "paused"}} = Handbean.Schedule.Store.get(schedule.id)

      view |> element("#{card} [phx-click='schedule_resume']") |> render_click()
      assert has_element?(view, "#{card} [phx-click='schedule_pause']")
      assert {:ok, %{status: "active"}} = Handbean.Schedule.Store.get(schedule.id)

      create_default_conversation(view)
      refute has_element?(view, "#schedule-center")
      send(view.pid, {:schedule_changed, conversation["id"]})
      refute has_element?(view, card)

      render_patch(view, "/w/default/c/#{conversation["id"]}")
      view |> element("#schedule-nav") |> render_click()
      assert has_element?(view, card)
      assert has_element?(view, "#{card} button[phx-click='schedule_delete']")
      view |> element("#{card} [phx-click='schedule_delete']") |> render_click()
      refute has_element?(view, card)
      assert {:error, :not_found} = Handbean.Schedule.Store.get(schedule.id)

      {:ok, pending} =
        schedule
        |> Map.from_struct()
        |> Handbean.Schedule.Store.create()

      send(view.pid, {:schedule_changed, conversation["id"]})
      assert has_element?(view, "#schedule-#{pending.id}")
      assert {:ok, claim} = Handbean.Schedule.Store.claim(pending, pending.next_run_at)
      send(view.pid, {:schedule_changed, conversation["id"]})
      assert has_element?(view, "#schedule-#{pending.id}")

      assert {:ok, _} = Handbean.Schedule.Store.finish_run(claim.run, "completed")
      send(view.pid, {:schedule_changed, conversation["id"]})
      assert has_element?(view, "#schedule-#{pending.id}", "已完成")
      refute has_element?(view, "#once-schedule-dock")
    end

    test "creating a schedule from the center opens a new default-workspace conversation", %{
      conn: conn
    } do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_schedule_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      try do
        {:ok, project} = Handbean.WorkspaceStore.add(project_dir, name: "Schedule Project")

        {:ok, conversation} =
          Handbean.ConversationStore.create(project["id"], title: "Project chat")

        {:ok, view, html} = live(conn, "/w/#{project["id"]}/c/#{conversation["id"]}")
        origin_id = session_id_from_html(html)

        view |> element("#schedule-nav") |> render_click()
        assert has_element?(view, "#schedule-center")
        assert render(view) =~ "任务会在默认工作区的新对话中运行并返回结果"

        request = "工作日每天 09:00，把项目摘要发到这个聊天"

        view
        |> form("#schedule-ask", %{"request" => request})
        |> render_submit()

        html = render(view)
        new_id = session_id_from_html(html)

        refute has_element?(view, "#schedule-center")
        assert new_id != origin_id
        assert new_id != conversation["id"]
        assert {:ok, created} = Handbean.ConversationStore.get(new_id, include_timeline?: false)
        assert created["workspace_id"] == "default"
        assert html =~ request
        refute render(view) =~ ~s(data-session-id="#{conversation["id"]}")
      after
        File.rm_rf!(project_dir)
      end
    end

    test "revising a schedule from the center stays in the current conversation", %{conn: conn} do
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Scheduled check")

      {:ok, schedule} =
        Handbean.Schedule.Store.create(%{
          workspace_id: "default",
          conversation_id: conversation["id"],
          name: "检查编译",
          instruction: "汇报编译结果",
          time_zone: "Asia/Shanghai",
          model: "fake/model",
          rule: %{
            "kind" => "weekly",
            "weekdays" => [1, 2, 3, 4, 5],
            "times" => ["09:00"]
          }
        })

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      view |> element("#schedule-nav") |> render_click()

      view
      |> element("#schedule-#{schedule.id} [phx-click='schedule_revise']")
      |> render_click()

      request = "把「检查编译」改成：每天 10:00"

      view
      |> form("#schedule-ask", %{"request" => request})
      |> render_submit()

      html = render(view)
      refute has_element?(view, "#schedule-center")
      assert session_id_from_html(html) == conversation["id"]
      assert html =~ request
    end

    test "schedule center lists every task and opens its conversation", %{conn: conn} do
      {:ok, host} = Handbean.ConversationStore.create("default", title: "天气日报")

      {:ok, schedule} =
        Handbean.Schedule.Store.create(%{
          workspace_id: "default",
          conversation_id: host["id"],
          name: "每天天气",
          instruction: "报告今天天气",
          time_zone: "Asia/Shanghai",
          model: "fake/model",
          rule: %{
            "kind" => "weekly",
            "weekdays" => [1, 2, 3, 4, 5, 6, 7],
            "times" => ["09:00"]
          }
        })

      {:ok, other} = Handbean.ConversationStore.create("default", title: "别的对话")
      {:ok, view, _html} = live(conn, "/w/default/c/#{other["id"]}")
      card = "#schedule-#{schedule.id}"

      view |> element("#schedule-nav") |> render_click()

      assert has_element?(view, "#schedule-center #{card}")
      assert has_element?(view, "#{card} #schedule-#{schedule.id}-conversation", "天气日报")

      view
      |> element("#{card} #schedule-#{schedule.id}-conversation")
      |> render_click()

      html = render(view)
      refute has_element?(view, "#schedule-center")
      assert session_id_from_html(html) == host["id"]
    end

    test "deleted one-shots and recurring tools do not leave cards in the composer dock",
         %{
           conn: conn
         } do
      old_once = %{
        "id" => "old-once-tool",
        "content_type" => "tool",
        "tool_name" => "schedule",
        "input" => %{
          "action" => "create",
          "name" => "很早以前的检查",
          "instruction" => "即使消息很多也保留删除态",
          "rule" => %{"kind" => "once", "at" => "2026-10-12T01:05:00Z"}
        },
        "output" => Handbean.JSON.encode!(%{"id" => "old-gone-once"})
      }

      later_messages =
        Enum.map(1..101, fn index ->
          %{
            "id" => "later-user-#{index}",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "later message #{index}"
          }
        end)

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          title: "Schedule projection",
          timeline: [old_once | later_messages]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      refute has_element?(view, "#once-schedule-dock")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "once-deleted",
           tool: "schedule",
           input: %{
             "action" => "create",
             "name" => "检查编译",
             "instruction" => "汇报测试和打包结果",
             "rule" => %{"kind" => "once", "at" => "2026-10-12T02:05:00Z"}
           }
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "once-deleted",
             tool: "schedule",
             output: Handbean.JSON.encode!(%{"id" => "gone-once"})
           },
           2
         )}
      )

      refute has_element?(view, "#once-schedule-dock")
      refute has_element?(view, "#once-card-tool-once-deleted [phx-click='schedule_delete']")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{
             tool_use_id: "recurring-deleted",
             tool: "schedule",
             input: %{
               "action" => "create",
               "rule" => %{"kind" => "interval", "every_minutes" => 5}
             }
           },
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "recurring-deleted",
             tool: "schedule",
             output: Handbean.JSON.encode!(%{"id" => "gone-recurring"})
           },
           4
         )}
      )

      refute has_element?(view, "#once-card-tool-recurring-deleted")

      create_default_conversation(view)
      refute has_element?(view, "#once-schedule-dock")

      render_patch(view, "/w/default/c/#{conversation["id"]}")
      refute has_element?(view, "#once-schedule-dock")

      render_click(view, "new_free_conversation")
      refute has_element?(view, "#once-schedule-dock")
    end

    test "tool_end event with error shows error status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "rm -rf /"}})}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool: "bash", duration_ms: 120, error: "Permission denied"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "Ran 1 command"
      assert rendered =~ "Permission denied"
    end

    test "browser missing-binary tool_end shows a copyable install card", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_browser_missing",
           tool: "browser",
           input: %{args: ["open", "https://example.com"]}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_browser_missing",
             tool: "browser",
             duration_ms: 12,
             error: "agent-browser is not installed",
             details: %{
               failure_category: "missing-binary",
               install_command: Handbean.Browser.InstallPrompt.command(),
               next_actions: [%{id: "install-agent-browser"}]
             }
           },
           2
         )}
      )

      assert has_element?(view, "#browser-install-tool-tu_browser_missing")

      assert has_element?(
               view,
               "#browser-install-tool-tu_browser_missing",
               Handbean.Browser.InstallPrompt.command()
             )

      assert has_element?(view, "#browser-install-copy-tool-tu_browser_missing")

      html = render(view)

      refute html =~ ~s("agent-browser is not installed")
    end

    test "tool_end event with details.file_path but no diff does not add to editor_files", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "my_module.ex")
      File.write!(file_path, "defmodule MyModule do end")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{tool: "edit", input: %{file_path: file_path}})}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "edit",
               duration_ms: 100,
               details: %{file_path: file_path}
             },
             2
           )}
        )

        rendered = render(view)
        assert has_element?(view, ".workspace-file-row.file", "my_module.ex")
        refute rendered =~ "defmodule MyModule do end"
      after
        File.rm(file_path)
      end
    end

    test "tool_end event with direct file_path but no diff does not add to editor_files", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "foo.ex")
      File.write!(file_path, "# foo")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_end, %{tool: "edit", duration_ms: 100, file_path: file_path})}
        )

        rendered = render(view)
        assert has_element?(view, ".workspace-file-row.file", "foo.ex")
        refute rendered =~ "# foo"
      after
        File.rm(file_path)
      end
    end

    test "tool_end event with non-empty diff adds to editor_files", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "changed.ex")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      refute has_element?(
               view,
               "button[phx-click='select_workspace_file'][phx-value-path='changed.ex']"
             )

      try do
        File.write!(file_path, "# changed")

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "edit",
               duration_ms: 100,
               details: %{
                 file_path: file_path,
                 diff_lines: [%{"type" => "ins", "text" => "# changed"}]
               }
             }
           )}
        )

        rendered = render(view)
        assert rendered =~ "changed.ex"

        assert has_element?(
                 view,
                 "button[phx-click='select_workspace_file'][phx-value-path='changed.ex']"
               )
      after
        File.rm(file_path)
      end
    end

    test "workspace file menu always offers path copies but hides undeclared file managers", %{
      conn: conn
    } do
      host = Application.get_env(:handbean, :host, %{})
      Handbean.Host.put!(Map.delete(host, :file_manager_backend))
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               "#workspace-tree-context-menu[role='menu'][hidden][phx-update='ignore']"
             )

      assert has_element?(
               view,
               "#workspace-tree-context-menu [data-workspace-tree-action='copy-absolute']",
               "Copy absolute path"
             )

      assert has_element?(
               view,
               "#workspace-tree-context-menu [data-workspace-tree-action='copy-relative']",
               "Copy relative path"
             )

      refute has_element?(
               view,
               "#workspace-tree-context-menu [data-workspace-tree-action='reveal-in-file-manager']"
             )
    end

    test "declared macOS file manager reveals only validated workspace entries", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      directory = Path.join(ws, "reveal-dir")
      file = Path.join(ws, "reveal-file.txt")
      symlink = Path.join(ws, "reveal-link")
      File.mkdir_p!(directory)
      File.write!(file, "reveal")
      File.ln_s!(Path.join(ws, "missing-target"), symlink)

      host = Application.get_env(:handbean, :host, %{})
      Handbean.Host.put!(Map.put(host, :file_manager_backend, FileManagerStub))
      Application.put_env(:handbean, :file_manager_test_owner, self())
      on_exit(fn -> Application.delete_env(:handbean, :file_manager_test_owner) end)

      try do
        {:ok, view, _html} = live(conn, "/")

        assert has_element?(
                 view,
                 "#workspace-tree-context-menu [data-workspace-tree-action='reveal-in-file-manager'][hidden]",
                 "Reveal in Finder"
               )

        assert has_element?(
                 view,
                 ".workspace-file-row.directory[data-workspace-relative-path='reveal-dir'][data-workspace-absolute-path='#{directory}']"
               )

        assert has_element?(
                 view,
                 ".workspace-file-entry[data-workspace-relative-path='reveal-file.txt'][data-workspace-absolute-path='#{file}']"
               )

        assert has_element?(
                 view,
                 ".workspace-file-row.symlink[data-workspace-relative-path='reveal-link'][data-workspace-absolute-path='#{symlink}']"
               )

        render_click(view, "reveal_in_file_manager", %{"path" => "reveal-file.txt"})
        assert_receive {:revealed, ^file}

        render_click(view, "reveal_in_file_manager", %{"path" => "reveal-dir"})
        assert_receive {:revealed, ^directory}

        render_click(view, "reveal_in_file_manager", %{"path" => "reveal-link"})
        assert_receive {:revealed, ^symlink}

        render_click(view, "reveal_in_file_manager", %{"path" => "../outside"})
        refute_receive {:revealed, _}
      after
        File.rm_rf!(directory)
        File.rm(file)
        File.rm(symlink)
      end
    end

    test "workspace tree lazily expands directories and selects a nested file", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join([ws, "nested", "compact-tab.ex"])
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "# compact")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      try do
        assert has_element?(view, ".workspace-file-row.directory", "nested")
        refute has_element?(view, ".workspace-file-row.file", "compact-tab.ex")

        view
        |> element("button[phx-click='toggle_workspace_directory'][phx-value-path='nested']")
        |> render_click()

        assert has_element?(
                 view,
                 ".workspace-file-row.file[title='nested/compact-tab.ex']",
                 "compact-tab.ex"
               )

        assert has_element?(
                 view,
                 "button.workspace-file-copy[data-copy='nested/compact-tab.ex'][aria-label='Copy relative path']"
               )

        refute has_element?(view, "button.workspace-file-copy[data-copy='nested']")

        view
        |> element(
          "button[phx-click='select_workspace_file'][phx-value-path='nested/compact-tab.ex']"
        )
        |> render_click()

        assert render(view) =~ "# compact"
      after
        File.rm_rf(Path.dirname(file_path))
      end
    end

    test "hosts without terminal capability hide every entry and reject direct open events", %{
      conn: conn
    } do
      previous = Application.get_env(:handbean, :host)
      Handbean.Host.put!(Map.put(previous || %{}, :terminal, false))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:handbean, :host, previous),
          else: Application.delete_env(:handbean, :host)
      end)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#mobile-open-files")
      refute has_element?(view, "#mobile-open-terminal")
      refute has_element?(view, "button[phx-value-view='terminal']")
      refute has_element?(view, "#status-bar button[phx-click='toggle_terminal']")

      for {event, params} <- [
            {"select_right_panel_view", %{"view" => "terminal"}},
            {"select_mobile_right_panel_view", %{"view" => "terminal"}},
            {"toggle_terminal", %{}}
          ] do
        render_click(view, event, params)
        refute has_element?(view, "#terminal-panel")
        refute has_element?(view, "#workspace-panel.mobile-panel-open")
      end

      view |> element("#mobile-open-files") |> render_click()
      assert has_element?(view, "#workspace-panel.mobile-panel-open")
      assert has_element?(view, ".workspace-panel-tab.active", "Files")
    end

    test "terminal opens inside the right workspace panel instead of a bottom dock", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='select_right_panel_view'][phx-value-view='terminal']")
      |> render_click()

      assert has_element?(view, "#workspace-panel #terminal-panel")
      assert has_element?(view, "#terminal-command-form input[name='line']")
      refute has_element?(view, "button", "+ New Terminal")
      refute render(view) =~ "args (space-separated)"
      refute render(view) =~ "no terminals"
      refute has_element?(view, "#terminal-dock")
      refute has_element?(view, "#status-bar button[phx-click='toggle_terminal']")
    end

    test "mobile header can open files and terminal in the workspace panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#mobile-open-files")
      assert has_element?(view, "#mobile-open-terminal")
      refute has_element?(view, "#workspace-panel.mobile-panel-open")

      view |> element("#mobile-open-files") |> render_click()
      assert has_element?(view, "#workspace-panel.mobile-panel-open")
      assert has_element?(view, "#workspace-panel .workspace-panel-tab.active", "Files")

      view |> element("#mobile-close-workspace-panel") |> render_click()
      refute has_element?(view, "#workspace-panel.mobile-panel-open")

      view |> element("#mobile-open-terminal") |> render_click()
      assert has_element?(view, "#workspace-panel.mobile-panel-open")
      assert has_element?(view, "#workspace-panel #terminal-panel")
    end

    test "duplicate file_path does not add duplicate editor file", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "dup.ex")
      File.write!(file_path, "# dup")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_end, %{
             tool: "edit",
             duration_ms: 100,
             file_path: file_path,
             details: %{diff_lines: [%{"type" => "ins", "text" => "# dup"}]}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "write",
               duration_ms: 200,
               file_path: file_path,
               details: %{diff_lines: [%{"type" => "ins", "text" => "# dup"}]}
             },
             2
           )}
        )

        rendered = render(view)
        assert rendered =~ "dup.ex"
      after
        File.rm(file_path)
      end
    end

    test "multiple tool events show all in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "a.txt"}})}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 50}, 2)})

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "ls"}}, 3)}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "bash", duration_ms: 100}, 4)})

      rendered = render(view)
      assert rendered =~ "id=\"tool-event-read\""
      assert rendered =~ "id=\"tool-event-bash\""
      assert rendered =~ "✓"
    end

    test "run_end event stops running and updates status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Set running via event (avoid Task race from render_submit)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      assert render(view) =~ "running"

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 3})})

      rendered = render(view)
      assert rendered =~ "completed"
      assert has_element?(view, "#status-turns", "3")
    end

    test "usage updates refresh the running footer and replace cumulative totals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:usage_updated, %{usage: %{input_tokens: 10, output_tokens: 15}}, 2)}
      )

      assert has_element?(view, "#status-input-tokens", "10")
      assert has_element?(view, "#status-output-tokens", "15")
      assert has_element?(view, "button[phx-click='stop_run']")

      payload = %{
        "usage" => %{
          "input_tokens" => 25,
          "output_tokens" => 35,
          "cache_read_input_tokens" => 7,
          "cache_creation_input_tokens" => 3
        }
      }

      for seq <- [3, 4] do
        send(view.pid, {:agent_event, agent_event(:usage_updated, payload, seq)})
        assert has_element?(view, "#status-input-tokens", "25")
        assert has_element?(view, "#status-output-tokens", "35")
        refute has_element?(view, "#status-cache-tokens")
      end

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{status: "completed", turns: 2, usage: payload["usage"]}, 5)}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"}, 6)})
      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: :cancelled}, 7)})
      send(view.pid, {:agent_event, agent_event(:usage_updated, payload, 8)})
      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
    end

    test "cache hit rate follows cumulative usage through completion and resets for a new run", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})
      assert has_element?(view, "#status-cache-hit-rate", "—")

      usage = %{input_tokens: 100, total_input_tokens: 100, cache_read_input_tokens: 80}

      for seq <- [2, 3] do
        send(view.pid, {:agent_event, agent_event(:usage_updated, %{usage: usage}, seq)})
        assert has_element?(view, "#status-cache-hit-rate", "80.0%")
      end

      cumulative = %{
        "input_tokens" => 150,
        "total_input_tokens" => 1000,
        "cache_read_input_tokens" => 180,
        "cache_creation_input_tokens" => 750
      }

      send(view.pid, {:agent_event, agent_event(:usage_updated, %{"usage" => cumulative}, 4)})
      assert has_element?(view, "#status-cache-hit-rate", "18.0%")
      assert has_element?(view, "button[phx-click='stop_run']")

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{"status" => "completed", "usage" => cumulative}, 5)}
      )

      assert has_element?(view, "#status-cache-hit-rate", "—")
      assert has_element?(view, "#status-input-tokens[title='0']", "0")
      refute has_element?(view, "button[phx-click='stop_run']")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"}, 6)})
      assert has_element?(view, "#status-cache-hit-rate", "—")
    end

    test "token footer keeps input/output while cache read/write totals stay hidden", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})
      assert has_element?(view, "#status-input-tokens[title='0']", "0")

      usage = %{
        input_tokens: 5481,
        output_tokens: 827,
        cache_read_input_tokens: 999_950,
        cache_creation_input_tokens: 1000
      }

      send(view.pid, {:agent_event, agent_event(:usage_updated, %{usage: usage}, 2)})
      assert has_element?(view, "button[phx-click='stop_run']")
      assert has_element?(view, "#status-input-tokens[title='5481']", "5.5K")
      assert has_element?(view, "#status-output-tokens[title='827']", "827")
      refute has_element?(view, "#status-cache-tokens")
      refute has_element?(view, "#status-cache-read")
      refute has_element?(view, "#status-cache-write")

      conv_id = session_id_from_html(render(view))

      :ok =
        Handbean.ConversationStore.record_run_usage(conv_id, "run-final", %{
          input_tokens: 33_261,
          output_tokens: 1250,
          cache_read_input_tokens: 1_200_000,
          cache_creation_input_tokens: 999
        })

      assert {:ok, usage_before} = Handbean.ConversationStore.get_token_usage(conv_id)

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{status: :completed, turns: 2, usage: %{input_tokens: 1}}, 3)}
      )

      refute has_element?(view, "button[phx-click='stop_run']")
      assert {:ok, ^usage_before} = Handbean.ConversationStore.get_token_usage(conv_id)
      assert has_element?(view, "#status-input-tokens[title='33261']", "33.3K")
      assert has_element?(view, "#status-output-tokens[title='1250']", "1.3K")
      refute has_element?(view, "#status-cache-tokens")
    end

    test "run_end event updates input and output token counts from provider usage", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{input_tokens: 12, output_tokens: 8}},
           2
         )}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
    end

    test "run_end accepts string-keyed provider usage", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{"input_tokens" => 9, "output_tokens" => 6}}
         )}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
    end

    test "run_end accepts string-keyed payload from persisted session events", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{
             "status" => "completed",
             "turns" => 2,
             "usage" => %{"input_tokens" => 21, "output_tokens" => 13}
           }
         )}
      )

      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
      assert has_element?(view, "#status-turns", "2")
    end

    test "switching conversations loads that conversation's totals and clears turns", %{
      conn: conn
    } do
      {:ok, first} =
        Handbean.ConversationStore.create("default", id: "conv-usage-a", title: "Usage A")

      :ok =
        Handbean.ConversationStore.record_run_usage(first["id"], "run-a", %{
          input_tokens: 100,
          output_tokens: 5,
          cache_read_input_tokens: 50,
          total_input_tokens: 200
        })

      {:ok, second} =
        Handbean.ConversationStore.create("default", id: "conv-usage-b", title: "Usage B")

      :ok =
        Handbean.ConversationStore.record_run_usage(second["id"], "run-b", %{
          input_tokens: 7,
          output_tokens: 1
        })

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 10}, 2)})

      assert has_element?(view, "#status-cache-hit-rate", "—")
      assert has_element?(view, "#status-input-tokens", "100")
      assert has_element?(view, "#status-turns", "10")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#status-input-tokens", "7")
      assert has_element?(view, "#status-cache-hit-rate", "—")
      refute has_element?(view, "#status-turns")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#status-cache-hit-rate", "—")
      assert has_element?(view, "#status-input-tokens", "100")
      refute has_element?(view, "#status-turns")
    end

    test "run_end with error status shows error in status bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "error", turns: 0, error: "timeout"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "Run error: timeout"
    end

    test "run_end clears running indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      refute has_element?(view, "#agent-working")
    end

    test "stop button cancels projection and ignores late streaming chunks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})
      assert has_element?(view, "button[phx-click='stop_run']", "Stop")

      view |> element("button[phx-click='stop_run']") |> render_click()

      assert has_element?(view, "#status-label", "cancelled")
      refute has_element?(view, "#agent-working")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "late chunk"}, 2)})
      refute render(view) =~ "late chunk"

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "new chunk"}, 4)})
      assert render(view) =~ "new chunk"
    end

    test "stop button ignores late tool events and stale completed run_end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})
      view |> element("button[phx-click='stop_run']") |> render_click()

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "bash", input: %{command: "mix test"}}, 2)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "bash", duration_ms: 25}, 3)}
      )

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 4)})

      rendered = render(view)
      refute rendered =~ "mix test"
      refute has_element?(view, "#tool-event-bash")
      assert has_element?(view, "#status-label", "cancelled")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"}, 5)})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "bash", input: %{command: "mix format"}}, 6)}
      )

      assert render(view) =~ "mix format"
    end

    test "unrecognized event kind is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:unknown_kind, %{foo: "bar"})})

      # View should still be alive and render the status bar
      rendered = render(view)
      assert rendered =~ "id=\"status-bar\""
    end

    test "streaming chunks render incrementally without losing content on run_end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Start a run
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      # Simulate streaming: many small chunks (like real SSE streaming)
      chunks = ["Hello", ", ", "this ", "is ", "a ", "streaming ", "test."]

      Enum.each(chunks, fn chunk ->
        send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: chunk})})
      end)

      # All chunks should have accumulated into one assistant message
      full_text = Enum.join(chunks)
      assert render(view) =~ full_text

      # Run ends — content should still be present
      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{input_tokens: 5, output_tokens: 7}},
           99
         )}
      )

      rendered = render(view)
      assert rendered =~ full_text
      assert rendered =~ "completed"
      refute has_element?(view, "#agent-working")
    end

    test "streaming chunks render before run_end", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "AI response"})})
      assert render(view) =~ "AI response"
    end

    test "conversation store is updated during streaming chunks and finalized on run_end", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)

      Handbean.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_start, %{model: "test"}}
      )

      Handbean.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_end, %{status: "completed", turns: 1}}
      )

      _ = render(view)

      # Now send streaming chunks — display history should be durable before run_end.
      for i <- 1..20 do
        Handbean.Agent.TranscriptPersistence.handle_event(
          conversation_id,
          {:message_delta, %{chunk: "chunk#{i} "}}
        )
      end

      assert {:ok, [streaming]} =
               Handbean.ConversationTranscriptStore.list(conversation_id)

      expected = Enum.map_join(1..20, &"chunk#{&1} ")
      assert streaming["content"] == expected
      assert streaming["status"] == "streaming"

      # Finalization must preserve the already durable content.
      Handbean.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_end,
         %{status: "completed", turns: 2, usage: %{input_tokens: 10, output_tokens: 20}}}
      )

      assert {:ok, [completed]} =
               Handbean.ConversationTranscriptStore.list(conversation_id)

      assert completed["content"] == expected
      assert completed["status"] == "completed"

      assert {:ok, conversation} = Handbean.ConversationStore.get(conversation_id)
      assert [projected] = conversation["timeline"]
      assert projected["content"] == expected
      assert projected["status"] == "completed"
    end
  end

  describe "preview and browser cards" do
    test "preview_serve tool_end renders open preview card without covering composer", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "preview-card"

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "preview_serve",
          duration_ms: 12,
          details: %{
            preview_id: "pv_live",
            title: "Demo site",
            conversation_id: "conv-preview-card",
            preview_path: "/preview/pv_live"
          }
        })
      )

      rendered = render(view)
      assert rendered =~ "preview-card"
      assert rendered =~ "Open preview"
      assert rendered =~ "Open in browser"
      assert rendered =~ "Demo site"
      assert rendered =~ ~s(id="composer") or rendered =~ "phx-submit=\"send_message\""
    end

    test "needs_user browser result shows takeover prompt, not an auto overlay", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "browser",
          duration_ms: 8,
          details: %{
            needs_user: true,
            reason: "captcha",
            session_id: "bws_live",
            backend: "webview"
          }
        })
      )

      rendered = render(view)
      assert rendered =~ "Take over browser"
      assert rendered =~ "captcha"
      refute rendered =~ "Mob.UI.webview"
    end
  end

  describe "file preview" do
    test "default workspace preview is isolated from inherited project overrides", %{conn: conn} do
      System.put_env("HANDBEAN_WORKSPACE", Path.join(Handbean.Home.path(), "inherited-project"))
      isolate_conversation_home!()
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      assert Handbean.Workspace.root() == workspace["path"]

      path = Path.join(Handbean.Workspace.ensure_root!(), "isolated-preview.txt")
      File.write!(path, "isolated preview fixture")
      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      view
      |> element(
        "button[phx-click='select_workspace_file'][phx-value-path='isolated-preview.txt']"
      )
      |> render_click()

      assert render(view) =~ "isolated preview fixture"
    end

    test "a deleted inactive tab can be selected and switching back restores its neighbor", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      File.write!(Path.join(ws, "tab-a.txt"), "content from tab A")
      File.write!(Path.join(ws, "tab-b.txt"), "content from tab B")
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)

      render_click(view, "select_workspace_file", %{"path" => "tab-a.txt"})
      render_click(view, "select_workspace_file", %{"path" => "tab-b.txt"})
      render_click(view, "select_editor_file", %{"path" => "tab-a.txt"})
      File.rm!(Path.join(ws, "tab-b.txt"))

      view
      |> element("[role='tab'][phx-value-path='tab-b.txt']")
      |> render_click()

      assert has_element?(view, "[role='tab'][aria-selected='true']", "tab-b.txt")
      assert render(view) =~ "File no longer exists"
      assert Handbean.ConversationStore.load_files(conversation_id)["active_file"] == "tab-b.txt"

      view
      |> element("[role='tab'][phx-value-path='tab-a.txt']")
      |> render_click()

      assert has_element?(view, "[role='tab'][aria-selected='true']", "tab-a.txt")
      assert render(view) =~ "content from tab A"
      refute render(view) =~ "File no longer exists"
    end

    test "invalid Markdown targets report errors without changing the current file preview", %{
      conn: conn
    } do
      ws = Handbean.Workspace.ensure_root!()
      File.write!(Path.join(ws, "current.md"), "# Current document")
      File.write!(Path.join(ws, "unopened.md"), "# Unopened document")
      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)
      render_click(view, "select_workspace_file", %{"path" => "current.md"})

      for event <- ["select_file", "select_workspace_file"] do
        render_click(view, event, %{"path" => "missing.md"})
        assert has_element?(view, "#flash-error", "File no longer exists")
        assert has_element?(view, "[role='tab'][aria-selected='true']", "current.md")
        assert render(view) =~ "Current document"

        assert Handbean.ConversationStore.load_files(conversation_id)["active_file"] ==
                 "current.md"
      end

      render_click(view, "select_editor_file", %{"path" => "unopened.md"})
      refute has_element?(view, "[role='tab']", "unopened.md")
      assert has_element?(view, "[role='tab'][aria-selected='true']", "current.md")
    end

    test "Agent updates to the active image refresh its URL and served content", %{conn: conn} do
      before_image =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
        )

      after_image =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg=="
        )

      assert byte_size(before_image) == byte_size(after_image)
      path = Path.join(Handbean.Workspace.ensure_root!(), "current.png")
      File.write!(path, before_image)
      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)
      render_click(view, "select_workspace_file", %{"path" => "current.png"})

      image_src = fn ->
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("img[alt='current.png']")
        |> Floki.attribute("src")
        |> List.first()
      end

      before_src = image_src.()
      assert response(get(conn, before_src), 200) == before_image
      File.write!(path, after_image)

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "edit",
          duration_ms: 100,
          file_path: path,
          details: %{diff_lines: [%{"type" => "ins", "text" => "updated image"}]}
        })
      )

      after_src = image_src.()
      assert after_src != before_src
      assert response(get(conn, after_src), 200) == after_image
      assert has_element?(view, "[role='tab'][aria-selected='true']", "current.png")
    end

    test "opening a file after the asynchronous sidebar loads preserves restored tabs across reload",
         %{
           conn: conn
         } do
      root = Handbean.Workspace.ensure_root!()

      for name <- ["restored-a.ex", "restored-b.ex", "new-c.ex"],
          do: File.write!(Path.join(root, name), "content of #{name}")

      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Restored tabs")
      id = conversation["id"]
      url = "/w/default/c/#{id}"

      :ok =
        Handbean.ConversationStore.save_files(id, %{
          "editor_files" => Enum.map(["restored-a.ex", "restored-b.ex"], &%{"path" => &1}),
          "active_file" => "restored-b.ex"
        })

      {:ok, view, _html} = live(conn, url)
      html = render_async(view, 5_000)
      refute html =~ ~s(id="conversation-list-loading")
      assert html =~ ~s(data-conversation-id="#{id}")
      assert has_element?(view, "[role='tab'][aria-selected='true']", "restored-b.ex")

      render_click(view, "select_workspace_file", %{"path" => "new-c.ex"})

      for name <- ["restored-a.ex", "restored-b.ex", "new-c.ex"],
          do: assert(has_element?(view, "[role='tab']", name))

      assert has_element?(view, "[role='tab'][aria-selected='true']", "new-c.ex")
      stored = Handbean.ConversationStore.load_files(id)

      assert Enum.map(stored["editor_files"], & &1["path"]) ==
               ["restored-a.ex", "restored-b.ex", "new-c.ex"]

      assert stored["active_file"] == "new-c.ex"

      {:ok, restored, _html} = live(recycle(conn), url)
      render_async(restored, 5_000)

      for name <- ["restored-a.ex", "restored-b.ex", "new-c.ex"],
          do: assert(has_element?(restored, "[role='tab']", name))

      assert has_element?(restored, "[role='tab'][aria-selected='true']", "new-c.ex")
    end

    test "mount restores the active relative file before editor defaults exist", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      File.write!(Path.join(ws, "restored.ex"), "# restored on initial mount")
      {:ok, conversation} = Handbean.ConversationStore.create("default", title: "Restored files")

      :ok =
        Handbean.ConversationStore.save_files(conversation["id"], %{
          "editor_files" => [%{"path" => "restored.ex", "name" => "restored.ex"}],
          "active_file" => "restored.ex"
        })

      {:ok, view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert Process.alive?(view.pid)
      assert html =~ "# restored on initial mount"

      assert has_element?(
               view,
               "button[phx-click='close_editor_file'][phx-value-path='restored.ex']"
             )
    end

    test "render_file_preview returns content for valid file" do
      ws = Handbean.Workspace.ensure_root!()
      tmp = Path.join(ws, "sigil_lv_test_preview.txt")
      File.write!(tmp, "hello\nworld")

      try do
        result = HandbeanWeb.WorkspaceLive.render_file_preview(tmp)
        assert result =~ "hello"
        assert result =~ "world"
      after
        File.rm(tmp)
      end
    end

    test "render_file_preview returns access denied for non-existent file" do
      result = HandbeanWeb.WorkspaceLive.render_file_preview("/nonexistent/path.txt")
      assert result =~ "Access denied"
    end

    test "render_file_preview returns empty for nil" do
      assert HandbeanWeb.WorkspaceLive.render_file_preview(nil) == ""
    end

    test "select_file shows error for non-existent file in UI", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      bad_path = Path.join(ws, "nonexistent.txt")

      {:ok, view, _html} = live(conn, "/")

      # A missing tool path must not appear in the workspace tree or open a preview.
      send(
        view.pid,
        agent_event(:tool_end, %{tool: "edit", duration_ms: 100, file_path: bad_path})
      )

      refute has_element?(view, ".workspace-file-row.file", "nonexistent.txt")
      refute has_element?(view, "#editor-content")
    end

    test "select_file shows file content in preview", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      tmp = Path.join(ws, "sigil_lv_test_ui.txt")
      File.write!(tmp, "preview content line 1")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      try do
        # Add a file to editor_files
        send(
          view.pid,
          agent_event(:tool_end, %{
            tool: "edit",
            duration_ms: 100,
            file_path: tmp,
            details: %{diff_lines: [%{"type" => "ins", "text" => "preview content line 1"}]}
          })
        )

        view
        |> element(
          "button[phx-click='select_workspace_file'][phx-value-path='sigil_lv_test_ui.txt']"
        )
        |> render_click()

        rendered = render(view)
        assert rendered =~ "preview content line 1"
      after
        File.rm(tmp)
      end
    end

    test "selecting a binary workspace file keeps the LiveView alive", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      path = Path.join(ws, "sigil_lv_test.db-shm")
      File.write!(path, <<0, 0xFF, "sqlite">>)

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      try do
        view
        |> element(
          "button[phx-click='select_workspace_file'][phx-value-path='sigil_lv_test.db-shm']"
        )
        |> render_click()

        rendered = render(view)
        assert Process.alive?(view.pid)
        assert rendered =~ "This file format is not rendered in the workspace yet."
        assert rendered =~ "sigil_lv_test.db-shm"
      after
        File.rm(path)
      end
    end
  end

  describe "diff view" do
    test "diff_prefix returns line markers" do
      assert HandbeanWeb.WorkspaceLive.diff_prefix("ins") == "+"
      assert HandbeanWeb.WorkspaceLive.diff_prefix("del") == "-"
      assert HandbeanWeb.WorkspaceLive.diff_prefix("eq") == " "
      assert HandbeanWeb.WorkspaceLive.diff_prefix("skip") == "⋯"
    end

    test "view_diff renders structured escaped diff lines by timeline entry id", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "diff_target.ex")
      File.write!(file_path, "safe")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_edit_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_edit_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "del", "text" => "<script>alert('xss')</script>"},
                   %{"type" => "ins", "text" => "safe"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_edit_1-toggle") |> render_click()

        rendered = render(view)
        assert rendered =~ "id=\"chat-file-change-tool-tu_edit_1-diff\""
        assert rendered =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
        refute rendered =~ "<script>"
        assert has_element?(view, "#chat-file-change-tool-tu_edit_1", "edit")
        assert rendered =~ "+1"
        assert rendered =~ "diff-lineno"

        view
        |> element("button[phx-click='select_right_panel_view'][phx-value-view='changes']")
        |> render_click()

        changes = render(view)
        assert changes =~ "id=\"changes-file-net-"
        refute changes =~ "id=\"changes-file-tool-tu_edit_1\""

        view
        |> element("#workspace-changes [id^='changes-file-net-'][id$='-toggle']")
        |> render_click()

        opened = render(view)
        assert opened =~ "id=\"changes-file-net-"
        assert opened =~ "-diff\""
        assert opened =~ "safe"
      after
        File.rm(file_path)
      end
    end

    test "Show diff button hidden when diff_lines is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_edit_empty",
           tool: "edit",
           input: %{file_path: "some.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_edit_empty",
             tool: "edit",
             duration_ms: 10,
             details: %{diff_lines: []}
           },
           2
         )}
      )

      rendered = render(view)
      refute has_element?(view, "#chat-file-change-tool-tu_edit_empty")
      refute rendered =~ "file-change-card"
    end

    test "close_diff clears diff state and re-opening works", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "close_test.ex")
      File.write!(file_path, "content")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_close_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_close_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "eq", "text" => "content"},
                   %{"type" => "ins", "text" => "new"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_close_1-toggle") |> render_click()
        rendered = render(view)
        assert rendered =~ "id=\"chat-file-change-tool-tu_close_1-diff\""
        assert rendered =~ "new"

        view |> element("#chat-file-change-tool-tu_close_1-toggle") |> render_click()
        rendered = render(view)
        refute rendered =~ "id=\"chat-file-change-tool-tu_close_1-diff\""

        view |> element("#chat-file-change-tool-tu_close_1-toggle") |> render_click()
        rendered = render(view)
        assert rendered =~ "id=\"chat-file-change-tool-tu_close_1-diff\""
        assert rendered =~ "new"
      after
        File.rm(file_path)
      end
    end

    test "diff view renders skip lines safely with correct class", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "skip_test.ex")
      File.write!(file_path, "first")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_skip_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_skip_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "skip", "text" => "... 120 unchanged lines ..."},
                   %{"type" => "del", "text" => "old"},
                   %{"type" => "ins", "text" => "new"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_skip_1-toggle") |> render_click()
        rendered = render(view)

        # Skip line renders
        assert rendered =~ "diff-skip"
        # Text is safely escaped (contains dots, not raw HTML)
        assert rendered =~ "120 unchanged lines"
        # Skip prefix is ⋯
        assert rendered =~ "⋯"
      after
        File.rm(file_path)
      end
    end

    test "reverts a recorded edit change from diff view", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_edit_test.ex")
      before = "value = 1\n"
      after_text = "value = 2\n"
      File.write!(file_path, after_text)

      change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, before, after_text)

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_revert_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_revert_1",
               tool: "edit",
               duration_ms: 42,
               details:
                 %{
                   file_path: file_path,
                   diff_lines: change.diff_lines
                 }
                 |> Map.merge(change_event_details(change))
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_revert_1-toggle") |> render_click()
        assert render(view) =~ "Revert"

        view |> element("#chat-file-change-tool-tu_revert_1-revert") |> render_click()
        assert render(view) =~ "Confirm revert"

        view
        |> element("#chat-file-change-tool-tu_revert_1-confirm button", "Confirm revert")
        |> render_click()

        rendered = render(view)

        assert File.read!(file_path) == before
        assert rendered =~ "Reverted file to the recorded before state"
        assert rendered =~ "reverted"
      after
        File.rm(file_path)
      end
    end

    test "changes panel revert restores the session baseline, not the latest call", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_net_test.ex")
      first = "value = 1\n"
      middle = "value = 2\n"
      latest = "value = 3\n"
      File.write!(file_path, latest)

      first_change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, first, middle)
      second_change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, middle, latest)

      {:ok, view, _html} = live(conn, "/")

      try do
        send_recorded_edit(view, "tu_net_1", file_path, first_change)
        send_recorded_edit(view, "tu_net_2", file_path, second_change)

        view
        |> element("button[phx-click='select_right_panel_view'][phx-value-view='changes']")
        |> render_click()

        rendered = render(view)
        assert rendered =~ "id=\"changes-file-net-"
        refute rendered =~ "id=\"changes-file-tool-tu_net_2\""

        view
        |> element("#workspace-changes [id^='changes-file-net-'][id$='-toggle']")
        |> render_click()

        view
        |> element("#workspace-changes [id^='changes-file-net-'][id$='-revert']")
        |> render_click()

        view
        |> element("#workspace-changes button", "Confirm revert")
        |> render_click()

        assert File.read!(file_path) == first
        assert render(view) =~ "Reverted file to the recorded before state"
      after
        File.rm(file_path)
      end
    end

    test "blocks revert when file changed after diff", %{conn: conn} do
      ws = Handbean.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_conflict_test.ex")
      before = "value = 1\n"
      after_text = "value = 2\n"
      File.write!(file_path, after_text)

      change = Handbean.ChangeSnapshot.build_edit_snapshot(file_path, before, after_text)

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_conflict_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_conflict_1",
               tool: "edit",
               duration_ms: 42,
               details:
                 %{
                   file_path: file_path,
                   diff_lines: change.diff_lines
                 }
                 |> Map.merge(change_event_details(change))
             },
             2
           )}
        )

        view |> element("#chat-file-change-tool-tu_conflict_1-toggle") |> render_click()
        File.write!(file_path, "user changed\n")
        view |> element("#chat-file-change-tool-tu_conflict_1-revert") |> render_click()

        view
        |> element("#chat-file-change-tool-tu_conflict_1-confirm button", "Confirm revert")
        |> render_click()

        rendered = render(view)
        assert File.read!(file_path) == "user changed\n"
        assert rendered =~ "file changed since this diff"
        assert rendered =~ "conflict"
      after
        File.rm(file_path)
      end
    end
  end

  describe "status helpers" do
    test "render_tool_status returns correct labels" do
      assert HandbeanWeb.WorkspaceLive.render_tool_status(:running) == "running"
      assert HandbeanWeb.WorkspaceLive.render_tool_status(:done) == "done"
      assert HandbeanWeb.WorkspaceLive.render_tool_status(:error) == "error"
    end

    test "format_duration returns formatted time" do
      assert HandbeanWeb.WorkspaceLive.format_duration(nil) == nil
      assert HandbeanWeb.WorkspaceLive.format_duration(500) == "500ms"
      assert HandbeanWeb.WorkspaceLive.format_duration(1500) =~ "1.5s"
    end
  end

  describe "agent event dispatch compatibility" do
    test "accepts AgentEvent struct directly (bare struct via send)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, agent_event(:run_start, %{model: "direct-model"}))

      rendered = render(view)
      assert rendered =~ "direct-model"
      assert rendered =~ "running"
    end

    test "accepts {:agent_event, %AgentEvent{}} tuple form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "tuple-model"})})

      rendered = render(view)
      assert rendered =~ "tuple-model"
      assert rendered =~ "running"
    end

    test "accepts map-like agent_event (backward compat)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, %{kind: :run_start, payload: %{model: "map-model"}}})

      rendered = render(view)
      assert rendered =~ "map-model"
      assert rendered =~ "running"
    end

    test "tool_start with legacy :name key still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         %{kind: :tool_start, payload: %{name: "read", input: %{file_path: "x.txt"}}}}
      )

      assert has_element?(view, "#tool-event-read")
      assert has_element?(view, "#tool-event-read", "x.txt")
    end

    test "tool_end with legacy :name key still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, %{kind: :tool_start, payload: %{name: "bash", input: %{command: "ls"}}}}
      )

      send(
        view.pid,
        {:agent_event, %{kind: :tool_end, payload: %{name: "bash", duration_ms: 300}}}
      )

      rendered = render(view)
      assert rendered =~ "Ran 1 command"
      assert rendered =~ "tool-work-collapsed"
    end
  end

  describe "full event flow" do
    test "full run_start → tool_start → tool_end → message_delta → run_end cycle", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        sid = create_default_conversation(view)
        {:ok, _session} = Handbean.PubSub.Session.start_or_get(session_id: sid)
        {:ok, queue} = Handbean.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
        :ok = Handbean.PubSub.Session.attach_run(sid, self(), queue)
        topic = "session:#{sid}"

        # 1. User submits message
        send(
          view.pid,
          {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
        )

        view |> element("form") |> render_submit(%{"message" => "Read the config"})
        assert render(view) =~ "Read the config"

        # 2. Agent starts
        send(
          view.pid,
          {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
        )

        assert render(view) =~ "running"

        # 3. Tool starts
        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{tool: "read", input: %{file_path: "config/runtime.exs"}},
             2,
             topic
           )}
        )

        assert has_element?(view, "#tool-event-read", "runtime.exs")

        # 4. Tool ends
        send(
          view.pid,
          {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 150}, 3, topic)}
        )

        rendered = render(view)
        assert rendered =~ "Explored 1 file"
        assert rendered =~ "tool-work-collapsed"

        # 5. Assistant streams response
        send(
          view.pid,
          {:agent_event, agent_event(:message_delta, %{chunk: "The config contains"}, 4, topic)}
        )

        send(
          view.pid,
          {:agent_event, agent_event(:message_delta, %{chunk: " useful settings."}, 5, topic)}
        )

        assert render(view) =~ "The config contains useful settings."

        # 6. Run ends
        send(
          view.pid,
          {:agent_event, agent_event(:run_end, %{status: "completed", turns: 2}, 6, topic)}
        )

        rendered = render(view)
        assert rendered =~ "completed"
        assert rendered =~ "Turns:"
        assert rendered =~ "2"
        refute has_element?(view, "#agent-working")
      end)
    end
  end

  describe "openai provider config" do
    test "openai_provider_config returns defaults when no env configured", %{conn: conn} do
      # Ensure no config is set
      Application.delete_env(:handbean, :openai)

      {:ok, _view, html} = live(conn, "/")

      # Status bar should show default OpenAI model
      assert html =~ "step-router-v1"
    end

    test "run_end with error status is handled without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{
             status: "error",
             turns: 0,
             error: "OPENAI_API_KEY not configured"
           },
           2
         )}
      )

      rendered = render(view)
      assert rendered =~ "Run error: OPENAI_API_KEY not configured"
      assert has_element?(view, "#status-bar")
    end
  end

  describe "new_session" do
    test "new_session button creates a new session and clears messages", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")

        # Send a message first
        view |> element("form") |> render_submit(%{"message" => "Hello"})
        assert render(view) =~ "Hello"

        # Create from the global new-conversation project picker.
        choose_new_conversation_project(view, "default")

        rendered = render(view)
        assert has_element?(view, "#no-messages")
        refute has_element?(view, "#timeline-stream .msg-user", "Hello")
        assert rendered =~ "No messages yet"
        assert rendered =~ "idle"
        assert rendered =~ "step-router-v1"
      end)
    end

    test "new_session preserves OpenAI model in status bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      choose_new_conversation_project(view, "default")

      rendered = render(view)
      assert rendered =~ "step-router-v1"
    end
  end

  describe "workspace integration" do
    setup do
      base_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_ws_case_#{System.unique_integer([:positive])}")

      store_path = Path.join(base_dir, "workspaces.json")
      old_home = System.get_env("HOME")
      home_dir = Path.join(base_dir, "home")
      ws_dir = Path.join(home_dir, ".handbean/workspace")

      File.mkdir_p!(base_dir)
      Application.put_env(:handbean, :host, %{data_dir: home_dir})
      System.put_env("HOME", home_dir)
      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", ws_dir)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        if File.exists?(base_dir), do: File.rm_rf!(base_dir)
      end)

      {:ok, ws_dir: ws_dir, home_dir: home_dir}
    end

    test "checkout picker heading has a zh_CN translation" do
      assert {:ok, _translation} =
               HandbeanWeb.Gettext.lgettext("zh_CN", "default", "Choose a checkout", %{})
    end

    test "adding two linked checkouts creates one workspace with checkout-bound conversations", %{
      conn: conn
    } do
      base =
        Path.join(System.tmp_dir!(), "sigil_linked_project_#{System.unique_integer([:positive])}")

      repo = Path.join(base, "repo")
      linked = Path.join(base, "linked")
      init_git_repo!(repo)
      git!(repo, ["worktree", "add", "-b", "feature", linked])

      try do
        {:ok, view, _html} = live(conn, "/")

        for {path, name} <- [{repo, "Repo"}, {linked, "Linked"}] do
          view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
          view |> render_keyup("update_add_path", %{"value" => path})
          view |> render_keyup("update_add_name", %{"value" => name})
          view |> element("button[phx-click='confirm_add_project']") |> render_click()
        end

        assert {:ok, main_workspace} = Handbean.WorkspaceStore.get_by_path(repo)
        assert {:ok, linked_workspace} = Handbean.WorkspaceStore.get_by_path(linked)
        assert main_workspace["id"] == linked_workspace["id"]

        conversations =
          Handbean.ConversationStore.list_for_workspace(main_workspace["id"])

        assert MapSet.new(Enum.map(conversations, & &1["checkout_path"])) ==
                 MapSet.new([
                   Handbean.Security.PathValidator.resolve_symlink(repo),
                   Handbean.Security.PathValidator.resolve_symlink(linked)
                 ])

        view
        |> element("#new-conversation-picker-toggle")
        |> render_click()

        html = render(view)
        assert html =~ ~s(id="new-conversation-picker")
        assert html =~ Path.basename(repo)
        assert html =~ Path.basename(linked)

        refute has_element?(
                 view,
                 "#new-conversation-project-#{main_workspace["id"]}"
               )

        linked_path = Handbean.Security.PathValidator.resolve_symlink(linked)
        before = Handbean.ConversationStore.list_for_workspace(main_workspace["id"])

        view
        |> element(
          "#new-conversation-picker button[phx-click='new_conversation_on_checkout'][phx-value-path='#{linked_path}']"
        )
        |> render_click()

        conversations = Handbean.ConversationStore.list_for_workspace(main_workspace["id"])

        assert Enum.count(conversations, &(&1["checkout_path"] == linked_path)) ==
                 Enum.count(before, &(&1["checkout_path"] == linked_path)) + 1

        assert length(Enum.reject(Handbean.WorkspaceStore.list(), & &1["default"])) == 1
        html = render(view)
        refute html =~ ~s(id="new-conversation-picker")
        assert html =~ ~s(data-checkout-path="#{linked_path}")
      after
        File.rm_rf!(base)
      end
    end

    test "workspace rows keep a new-conversation button next to the count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(
               view,
               "#workspace-group-default .workspace-row-actions button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']"
             )
    end

    test "new conversation in a single-checkout workspace still creates immediately", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      before = Handbean.ConversationStore.list_for_workspace("default")

      choose_new_conversation_project(view, "default")

      refute render(view) =~ ~s(id="new-conversation-picker")
      after_list = Handbean.ConversationStore.list_for_workspace("default")
      assert length(after_list) == length(before) + 1
    end

    test "adding a workspace creates a checkout-bound first conversation", %{conn: conn} do
      project_dir =
        Path.join(System.tmp_dir!(), "sigil_added_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        assert has_element?(view, "#add-project-builtin-memory[checked]")
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Added Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        rendered = render(view)

        assert rendered =~ "Added Project"
        refute rendered =~ "sid:none"
        assert rendered =~ "No messages yet"
        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(project_dir)
        assert Handbean.WorkspaceSettings.builtin_memory_enabled(project_dir)
        assert [conversation] = Handbean.ConversationStore.list_for_workspace(added_ws["id"])

        assert conversation["checkout_path"] ==
                 Handbean.Security.PathValidator.resolve_symlink(project_dir)
      after
        File.rm_rf!(project_dir)
      end
    end

    test "new workspace dialog can disable built-in memory", %{conn: conn} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_external_memory_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> element("#add-project-builtin-memory") |> render_click()
        refute has_element?(view, "#add-project-builtin-memory[checked]")

        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "External Memory"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        refute Handbean.WorkspaceSettings.builtin_memory_enabled(project_dir)
        assert {:ok, settings} = Handbean.WorkspaceSettings.load(project_dir)
        assert get_in(settings, ["memory", "builtin_enabled"]) == false
      after
        File.rm_rf!(project_dir)
      end
    end

    test "removing a workspace archives its conversations and keeps the directory", %{conn: conn} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_removed_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "keep.txt"), "still here")

      try do
        {:ok, added} = Handbean.WorkspaceStore.add(project_dir, name: "To Remove")

        {:ok, conversation} =
          Handbean.ConversationStore.create(added["id"],
            title: "Kept chat",
            timeline: [%{"id" => "kept-1", "role" => "user", "content" => "do not delete"}]
          )

        {:ok, view, _html} = live(conn, "/")

        rendered = render(view)
        assert rendered =~ ~s(id="workspace-hover-remove")
        refute rendered =~ "workspace-menu-#{added["id"]}"

        view
        |> render_click("open_remove_workspace", %{"id" => added["id"]})

        dialog = render(view)
        assert dialog =~ "Remove workspace"
        assert dialog =~ "archives its conversations"

        view |> element("#confirm-remove-workspace") |> render_click()

        rendered = render(view)
        refute rendered =~ "To Remove"
        assert rendered =~ "Archived"
        assert rendered =~ "Kept chat"
        assert File.read!(Path.join(project_dir, "keep.txt")) == "still here"
        assert {:error, :not_found} = Handbean.WorkspaceStore.get(added["id"])

        assert {:ok, archived} =
                 Handbean.ConversationStore.get(conversation["id"], include_timeline?: false)

        assert is_binary(archived["archived_at"])
      after
        File.rm_rf!(project_dir)
      end
    end

    test "sandbox host imports a copied directory as the workspace", %{conn: conn} do
      previous = Application.get_env(:handbean, :host)

      imported =
        Path.join(System.tmp_dir!(), "sigil_imported_ws_#{System.unique_integer([:positive])}")

      File.mkdir_p!(imported)
      File.write!(Path.join(imported, "README.md"), "from downloads")

      Handbean.Host.put!(%{
        data_dir:
          Path.join(System.tmp_dir!(), "handbean_host_#{System.unique_integer([:positive])}"),
        shell: false,
        terminal: false,
        browser_backend: nil
      })

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        assert render(view) =~ "Import from Downloads"

        send(view.pid, {:workspace_imported, %{path: imported, name: "Downloads Project"}})
        rendered = render(view)

        assert rendered =~ "Downloads Project"
        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(imported)
        assert added_ws["name"] == "Downloads Project"
      after
        if previous,
          do: Application.put_env(:handbean, :host, previous),
          else: Application.delete_env(:handbean, :host)

        File.rm_rf!(imported)
      end
    end

    test "status bar shows MCP and skills counts for the current workspace", %{conn: conn} do
      project_dir =
        Path.join(System.tmp_dir!(), "sigil_counts_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)
      File.mkdir_p!(Path.join(project_dir, ".handbean/skills/code-review"))
      File.mkdir_p!(Path.join(project_dir, ".handbean/skills/docs"))

      File.write!(
        Path.join(project_dir, ".mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "one" => %{"command" => "echo"},
            "two" => %{"command" => "printf"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".handbean/skills/code-review/SKILL.md"),
        """
        ---
        name: code-review
        description: Review code
        ---

        Review instructions.
        """
      )

      File.write!(
        Path.join(project_dir, ".handbean/skills/docs/SKILL.md"),
        """
        ---
        name: docs
        description: Write docs
        ---

        Docs instructions.
        """
      )

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Counted Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        assert has_element?(view, "#status-mcp-count", "2")
        assert has_element?(view, "#status-skills-count", "2")
      after
        File.rm_rf!(project_dir)
      end
    end

    test "status bar includes global MCP and skills counts", %{conn: conn, home_dir: home_dir} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_global_counts_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      File.mkdir_p!(Path.join(project_dir, ".handbean/skills/code-review"))
      File.mkdir_p!(Path.join(project_dir, ".agents/skills/docs"))
      File.mkdir_p!(Path.join(home_dir, ".handbean"))
      File.mkdir_p!(Path.join(home_dir, ".handbean/skills/global-review"))

      File.write!(
        Path.join(home_dir, ".handbean/mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "global" => %{"command" => "global-cmd"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "one" => %{"command" => "echo"},
            "two" => %{"command" => "printf"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".handbean/skills/code-review/SKILL.md"),
        """
        ---
        name: code-review
        description: Review code
        ---

        Review instructions.
        """
      )

      File.write!(
        Path.join(project_dir, ".agents/skills/docs/SKILL.md"),
        """
        ---
        name: docs
        description: Write docs
        ---

        Docs instructions.
        """
      )

      File.write!(
        Path.join(home_dir, ".handbean/skills/global-review/SKILL.md"),
        """
        ---
        name: global-review
        description: Global review
        ---

        Global review instructions.
        """
      )

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Global Counted Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        assert has_element?(view, "#status-mcp-count", "3")
        assert has_element?(view, "#status-skills-count", "3")
      after
        File.rm_rf!(project_dir)
      end
    end

    for {default_model, expected_model} <- [
          {"stepfun/step-router-v1", "stepfun/step-router-v1"},
          {"removed/model", "sui2api/gpt-5.5"}
        ] do
      @default_model default_model
      @expected_model expected_model

      test "new conversations resolve workspace default #{default_model} before persisting", %{
        conn: conn,
        ws_dir: ws_dir
      } do
        configure_test_models!()
        :ok = Handbean.Settings.save_global(%{"default_model" => "sui2api/gpt-5.5"})
        {:ok, view, _html} = live(conn, "/")
        first_id = create_default_conversation(view)
        render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

        # Read the workspace setting afresh, rather than the mounted socket's cached settings.
        :ok =
          Handbean.Settings.save_workspace_model_ai(ws_dir, %{"default_model" => @default_model})

        second_id = create_default_conversation(view)

        assert second_id != first_id
        assert has_element?(view, "#model-picker option[value='#{@expected_model}'][selected]")

        assert {:ok, %{"selected_model" => @expected_model}} =
                 Handbean.ConversationStore.get(second_id)

        assert {:ok, %{"selected_model" => "sui2api/gpt-5.5"}} =
                 Handbean.ConversationStore.get(first_id)

        view
        |> element(
          ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first_id}']"
        )
        |> render_click()

        assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

        view
        |> element(
          ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second_id}']"
        )
        |> render_click()

        assert has_element?(view, "#model-picker option[value='#{@expected_model}'][selected]")
      end
    end

    test "delegated conversations display their pinned model instead of a stale selection", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, parent} =
        Handbean.ConversationStore.create("default",
          title: "Delegation parent",
          selected_model: "stepfun/step-router-v1"
        )

      {:ok, child} =
        Handbean.ConversationStore.create("default",
          title: "Pinned child",
          parent_conversation_id: parent["id"],
          selected_model: "stepfun/step-router-v1",
          collaboration: %{
            "read_only" => true,
            "provider" => "sui2api",
            "model" => "gpt-5.5"
          }
        )

      {:ok, view, _html} = live(conn, "/")
      render_async(view, 5_000)

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{child["id"]}']"
      )
      |> render_click()

      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")
    end

    test "new conversations without a default inherit the model and retain independent selections",
         %{
           conn: conn
         } do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_per_conversation_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      first_conversation_id = create_default_conversation(view)

      render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

      choose_new_conversation_project(view, "default")

      second_html = render(view)
      second_conversation_id = session_id_from_html(second_html)
      assert second_conversation_id != first_conversation_id
      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

      assert {:ok, %{"selected_model" => "sui2api/gpt-5.5"}} =
               Handbean.ConversationStore.get(second_conversation_id)

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#model-picker option[value='stepfun/step-router-v1'][selected]")

      assert {:ok, %{"selected_model" => "stepfun/step-router-v1"}} =
               Handbean.ConversationStore.get(second_conversation_id)

      assert {:ok, %{"selected_model" => "sui2api/gpt-5.5"}} =
               Handbean.ConversationStore.get(first_conversation_id)

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first_conversation_id}']"
      )
      |> render_click()

      assert has_element?(view, "#model-picker option[value='sui2api/gpt-5.5'][selected]")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second_conversation_id}']"
      )
      |> render_click()

      assert has_element?(view, "#model-picker option[value='stepfun/step-router-v1'][selected]")
    end

    test "sending in a newly added workspace creates the first conversation", %{conn: conn} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_send_added_project_#{System.unique_integer([:positive])}"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_send_added_models_#{System.unique_integer([:positive])}.json"
        )

      File.mkdir_p!(project_dir)
      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Send Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        initial_id = render(view) |> session_id_from_html()

        view
        |> element("form")
        |> render_submit(%{"message" => "你好", "model" => "sui2api/gpt-5.5"})

        rendered = render(view)
        refute rendered =~ "sid:none"
        assert rendered =~ "你好"

        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(project_dir)
        assert [conversation] = Handbean.ConversationStore.list_for_workspace(added_ws["id"])
        assert conversation["id"] == initial_id

        runner_pid =
          case Registry.lookup(Handbean.AgentRunRegistry, conversation["id"]) do
            [{pid, _value}] -> pid
            [] -> nil
          end

        runner_ref = if is_pid(runner_pid), do: Process.monitor(runner_pid)
        _ = Handbean.Agent.Runner.cancel(conversation["id"])

        if runner_ref,
          do: assert_receive({:DOWN, ^runner_ref, :process, ^runner_pid, _reason}, 1_000)

        case Registry.lookup(Handbean.AgentRunRegistry, conversation["id"]) do
          [{pid, _value}] ->
            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

          [] ->
            :ok
        end
      after
        stop_test_runtime!(Process.get(:workspace_live_test_tracker))
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
        File.rm_rf!(project_dir)
      end
    end

    test "select_workspace creates an active conversation when only archived conversations exist",
         %{
           conn: conn
         } do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_archived_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Archived Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        {:ok, added_ws} = Handbean.WorkspaceStore.get_by_path(project_dir)
        assert [initial] = Handbean.ConversationStore.list_for_workspace(added_ws["id"])
        {:ok, _archived} = Handbean.ConversationStore.archive(initial["id"])

        choose_new_conversation_project(view, added_ws["id"])

        rendered = render(view)
        assert rendered =~ "Archived Project"
        refute rendered =~ "sid:none"

        active =
          added_ws["id"]
          |> Handbean.ConversationStore.list_for_workspace(include_archived?: false)

        assert length(active) == 1

        archived =
          added_ws["id"]
          |> Handbean.ConversationStore.list_for_workspace(include_archived?: true)
          |> Enum.filter(&Map.get(&1, "archived_at"))

        assert length(archived) == 1
      after
        File.rm_rf!(project_dir)
      end
    end

    test "parent thread toggle collapses descendants without selecting the parent", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()

      {:ok, parent} =
        Handbean.ConversationStore.create(workspace["id"],
          id: "thread-collapse-parent",
          title: "Collapsible parent"
        )

      {:ok, child} =
        Handbean.ConversationStore.create(workspace["id"],
          id: "thread-collapse-child",
          title: "Nested child",
          parent_conversation_id: parent["id"]
        )

      {:ok, view, _html} = live(conn, "/")
      render_async(view, 5_000)

      assert has_element?(view, "#conversation-#{child["id"]}")
      assert has_element?(view, "#thread-toggle-#{parent["id"]}[aria-expanded='true']")

      selected_before = view |> render() |> session_id_from_html()
      view |> element("#thread-toggle-#{parent["id"]}") |> render_click()

      refute has_element?(view, "#conversation-#{child["id"]}")
      assert has_element?(view, "#thread-toggle-#{parent["id"]}[aria-expanded='false']")
      assert view |> render() |> session_id_from_html() == selected_before

      view |> element("#thread-toggle-#{parent["id"]}") |> render_click()

      assert has_element?(view, "#conversation-#{child["id"]}")
      assert has_element?(view, "#thread-toggle-#{parent["id"]}[aria-expanded='true']")
    end

    test "workspace group shows conversation count and collapses", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      ws_id = workspace["id"]

      html = render(view)
      assert html =~ ~r/id="workspace-count-#{ws_id}"[^>]*>\s*\d+\s*</
      assert html =~ ~r/id="free-workspace-count"[^>]*>\s*\d+\s*</
      assert html =~ ~r/id="mobile-workspace-count"[^>]*>\s*\d+\s*</
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='true']")
      assert has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#sheet-workspace-count-#{ws_id}")
      assert has_element?(view, "#sheet-free-count")
      assert has_element?(view, "#sheet-free-toggle[aria-expanded='true']")
      assert has_element?(view, "#sheet-free-conversations")
      assert has_element?(view, "#free-workspace-toggle[aria-expanded='true']")
      assert has_element?(view, "#free-conversations")

      view
      |> element(".workspace-header[phx-click='toggle_workspace_group'][phx-value-id='#{ws_id}']")
      |> render_click()

      refute has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='false']")

      view
      |> element(".workspace-header[phx-click='toggle_workspace_group'][phx-value-id='#{ws_id}']")
      |> render_click()

      assert has_element?(view, "#workspace-conversations-#{ws_id}")

      view |> element("#workspace-toggle-#{ws_id}") |> render_click()

      refute has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#workspace-count-#{ws_id}")
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='false']")

      view |> element("#workspace-toggle-#{ws_id}") |> render_click()

      assert has_element?(view, "#workspace-conversations-#{ws_id}")
      assert has_element?(view, "#workspace-toggle-#{ws_id}[aria-expanded='true']")

      view |> element("#free-workspace-toggle") |> render_click()
      refute has_element?(view, "#free-conversations")
      refute has_element?(view, "#sheet-free-conversations")
      assert has_element?(view, "#free-workspace-count")
      assert has_element?(view, "#sheet-free-count")
      assert has_element?(view, "#sheet-free-toggle[aria-expanded='false']")
    end

    test "reopening / restores the last conversation and collapsed groups", %{conn: conn} do
      {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
      ws_id = workspace["id"]

      {:ok, older} =
        Handbean.ConversationStore.create(ws_id,
          id: "conv-restore-older",
          title: "Older stay",
          timeline: [
            %{
              "id" => "msg-older",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "stay on the older chat"
            }
          ]
        )

      {:ok, newer} =
        Handbean.ConversationStore.create(ws_id,
          id: "conv-restore-newer",
          title: "Newer chat",
          timeline: [
            %{
              "id" => "msg-newer",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "this is the newer chat"
            }
          ]
        )

      {:ok, _} =
        Handbean.ConversationStore.update_meta(older["id"],
          touch: false,
          updated_at: "2000-01-01T00:00:00Z"
        )

      {:ok, _} =
        Handbean.ConversationStore.update_meta(newer["id"],
          touch: false,
          updated_at: "2099-01-01T00:00:00Z"
        )

      {:ok, view, _html} = live(conn, "/")
      html = render_async(view, 5_000)
      assert html =~ "sid:#{newer["id"]}"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{older["id"]}']"
      )
      |> render_click()

      view |> element("#free-workspace-toggle") |> render_click()

      {:ok, restored, _html} = live(conn, "/")
      html = render_async(restored, 5_000)
      assert html =~ "sid:#{older["id"]}"
      assert html =~ "stay on the older chat"
      refute html =~ "sid:#{newer["id"]}"
      assert has_element?(restored, "#free-workspace-toggle[aria-expanded='false']")
      refute has_element?(restored, "#free-conversations")

      assert Handbean.Settings.UI.save_last_location(%{
               scope: :workspace,
               workspace_id: ws_id,
               conversation_id: "missing-conversation"
             }) == :ok

      {:ok, _fallback, html} = live(conn, "/")
      refute html =~ "sid:missing-conversation"
    end

    test "reopening / restores a free conversation", %{conn: conn} do
      {:ok, conv} =
        Handbean.ConversationStore.create_free(
          id: "conv-restore-free",
          title: "Free stay",
          timeline: [
            %{
              "id" => "msg-free",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "stay in free chat"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(
        ".conversation-item[phx-click='select_free_conversation'][phx-value-id='#{conv["id"]}']"
      )
      |> render_click()

      {:ok, _restored, html} = live(conn, "/")
      assert html =~ "sid:#{conv["id"]}"
      assert html =~ "stay in free chat"
    end

    test "mount renders the active workspace panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end

    test "tool_end with file_path adds editor tab with relative name", %{
      conn: conn,
      ws_dir: ws_dir
    } do
      # Create a file in the workspace
      file_path = Path.join(ws_dir, "hello.exs")
      File.write!(file_path, "IO.puts(\"hello world\")")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      # Send tool_end with file_path pointing to workspace file
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 100,
           file_path: file_path,
           details: %{diff_lines: [%{"type" => "ins", "text" => "IO.puts(\"hello world\")"}]}
         })}
      )

      rendered = render(view)
      # The tab should show the relative path (just the filename)
      assert rendered =~ "hello.exs"
    end

    test "tool_end with file_path auto-selects file if no active_file", %{
      conn: conn,
      ws_dir: ws_dir
    } do
      file_path = Path.join(ws_dir, "auto.exs")
      File.write!(file_path, "x = 1")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 120,
           file_path: file_path,
           details: %{diff_lines: [%{"type" => "ins", "text" => "x = 1"}]}
         })}
      )

      rendered = render(view)
      # Should show file content since auto-selected
      assert rendered =~ "x = 1"
    end

    test "tool_end with outside workspace path is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Send tool_end with a path outside the workspace
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "read",
           duration_ms: 50,
           file_path: "/etc/passwd"
         })}
      )

      rendered = render(view)
      # Should NOT show the sensitive file
      refute rendered =~ "passwd"
      # The workspace tree remains available and no preview is opened.
      assert has_element?(view, ".workspace-file-tree[role='tree']")
      refute has_element?(view, "#editor-content")
    end

    test "select_file outside workspace does not read system file" do
      result = HandbeanWeb.WorkspaceLive.render_file_preview("/etc/passwd")
      assert result =~ "Access denied"
    end

    test "render_file_preview shows content for workspace file", %{ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "preview.exs")
      File.write!(file_path, "defmodule Foo do\n  def bar, do: :ok\nend")

      result = HandbeanWeb.WorkspaceLive.render_file_preview(file_path)
      assert result =~ "defmodule Foo do"
      assert result =~ ":ok"
    end

    test "render_file_preview/2 shows content when file is in non-global custom workspace" do
      # Create a file in a directory that is NOT the global workspace
      custom_dir =
        Path.join(System.tmp_dir!(), "sigil_custom_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)

      file_path = Path.join(custom_dir, "custom.exs")
      File.write!(file_path, "defmodule Custom do\n  def run, do: :custom\nend")

      try do
        # render_file_preview/1 uses the global workspace root and should fail
        result1 = HandbeanWeb.WorkspaceLive.render_file_preview(file_path)
        assert result1 =~ "Access denied"

        # render_file_preview/2 with custom workspace_root should work
        result2 = HandbeanWeb.WorkspaceLive.render_file_preview(file_path, custom_dir)
        assert result2 =~ "defmodule Custom do"
        assert result2 =~ ":custom"
      after
        File.rm_rf!(custom_dir)
      end
    end

    test "tool_end with details from executor creates editor tab", %{conn: conn, ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "from_details.exs")
      File.write!(file_path, "# from details")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 90,
           details: %{
             file_path: file_path,
             bytes: 14,
             lines: 1,
             diff_lines: [%{"type" => "ins", "text" => "# from details"}]
           },
           file_path: file_path
         })}
      )

      rendered = render(view)
      assert rendered =~ "from_details.exs"
    end

    test "auto-selects newly created file", %{conn: conn, ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "hello.exs")
      File.write!(file_path, "IO.puts(\"hello world\")")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      # Simulate Agent writing hello.exs via write tool
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 100,
           file_path: file_path,
           details: %{
             file_path: file_path,
             bytes: 21,
             lines: 1,
             diff_lines: [%{"type" => "ins", "text" => "IO.puts(\"hello world\")"}]
           }
         })}
      )

      rendered = render(view)
      assert rendered =~ "hello.exs"
      assert rendered =~ "hello world"
    end
  end

  describe "model switching" do
    test "model picker shows current model on mount", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"model-picker\""
      assert html =~ "step-router-v1"
    end

    test "run_start event updates current model state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "custom-oai-model"})})

      rendered = render(view)
      assert rendered =~ "custom-oai-model"
    end

    test "model display persists across new_session", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      choose_new_conversation_project(view, "default")

      rendered = render(view)
      assert rendered =~ "step-router-v1"
    end

    test "workspace label remains visible in the workspace panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end
  end

  describe "conversation stream" do
    test "renders conversations under workspace groups", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "workspace-group"
      assert html =~ "conversations-list"

      choose_new_conversation_project(view, "default")

      assert render(view) =~ "conversation-row"
    end

    test "conversation items omit workspace badges inside grouped workspaces", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "workspace-badge"
    end

    test "workspace panel shows the active workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end

    test "new_conversation_in_workspace renders inside grouped workspace list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      choose_new_conversation_project(view, "default")

      html = render(view)
      assert html =~ "conversations-list"
      assert html =~ "conversation-row"
    end

    test "right workspace panel uses a single floating toggle instead of expand bar", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/")

      assert html =~ ~s(id="workspace-panel-collapse")
      refute html =~ ~s(id="workspace-expand-bar")

      view
      |> element("[data-workspace-panel-toggle]")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="workspace-panel-expand")
      assert html =~ "collapsed"
      refute html =~ ~s(id="workspace-expand-bar")
    end

    test "mobile workspace sheet has new conversation entry without duplicate workspace row", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#workspace-sheet[aria-hidden='true'][inert]")

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='workspace']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="workspace-sheet")
      assert has_element?(view, "#workspace-sheet.open[aria-hidden='false']:not([inert])")
      assert html =~ "sheet-new-conv-btn"
      refute html =~ "sheet-ws-row"
      assert has_element?(view, "#workspace-sheet #mobile-schedule-nav")

      view |> element("#mobile-schedule-nav") |> render_click()
      assert has_element?(view, "#schedule-center")
      refute has_element?(view, "#ai-input-area")
      refute has_element?(view, "#workspace-sheet.open")

      view |> element("#mobile-schedule-back") |> render_click()

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='workspace']")
      |> render_click()

      view
      |> element(
        "#workspace-sheet button[phx-click='mobile_new_conversation_in_workspace'][phx-value-ws_id='default']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "conversation-row"
      refute html =~ ~s(id="workspace-sheet" class="bottom-sheet open")
    end

    test "archive toggle shows archived conversations in stream", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render(view)
      assert html =~ "Archived"
      refute html =~ "Trash"

      assert has_element?(
               view,
               "button.workspace-header[phx-click='toggle_archive'][aria-expanded='false']"
             )

      view |> element("button.workspace-header[phx-click='toggle_archive']") |> render_click()

      assert has_element?(
               view,
               "button.workspace-header[phx-click='toggle_archive'][aria-expanded='true']"
             )
    end

    test "conversation stream scrolls past workspaces while preserving scroll position", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      html = render(view)
      assert html =~ "workspace-group"
      assert html =~ "conversations-list"
    end
  end

  describe "strip_think_tags" do
    test "strips think tags from plain text" do
      {thinking, clean, buffer} =
        HandbeanWeb.WorkspaceLive.strip_think_tags("", "<think>reasoning</think> answer")

      assert thinking == "reasoning"
      assert clean == " answer"
      assert buffer == ""
    end

    test "strips thinking tags variant" do
      {thinking, clean, _} =
        HandbeanWeb.WorkspaceLive.strip_think_tags("", "<thinking>deep thought</thinking> done")

      assert thinking == "deep thought"
      assert clean == " done"
    end

    test "handles text without think tags" do
      {thinking, clean, buffer} =
        HandbeanWeb.WorkspaceLive.strip_think_tags("", "plain text no tags")

      assert thinking == ""
      assert clean == "plain text no tags"
      assert buffer == ""
    end

    test "accumulates partial tags across chunk boundaries" do
      # First chunk: partial opening tag
      {t1, c1, buf1} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "<thi")
      assert t1 == ""
      assert c1 == ""

      # Second chunk: complete the tag and some thinking text
      {t2, c2, buf2} = HandbeanWeb.WorkspaceLive.strip_think_tags(buf1, "nk>thinking text")
      assert t2 == "thinking text"
      assert c2 == ""
      # Buffer encodes inside state; empty partial = still inside think block
      assert buf2 == "<in>"
    end

    test "accumulates partial closing tag across chunks" do
      {t1, c1, buf1} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "<think>inner</thi")
      assert t1 == "inner"
      assert c1 == ""

      # Combined: </thi + nk> = </think> closes block, "after" is outside, "/think> visible" is trailing
      {t2, c2, buf2} =
        HandbeanWeb.WorkspaceLive.strip_think_tags(buf1, "nk>after</think> visible")

      assert t2 == ""
      assert c2 == "after</think> visible"
      assert buf2 == ""
    end

    test "handles multiple think blocks" do
      {thinking, clean, _} =
        HandbeanWeb.WorkspaceLive.strip_think_tags(
          "",
          "<think>first</think> middle <think>second</think> end"
        )

      assert thinking == "firstsecond"
      assert clean == " middle  end"
    end

    test "handles empty input" do
      {t, c, b} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "")
      assert t == ""
      assert c == ""
      assert b == ""
    end

    test "think tag opens but never closes across many chunks" do
      {t1, c1, buf1} = HandbeanWeb.WorkspaceLive.strip_think_tags("", "prefix <think>reason")
      assert t1 == "reason"
      assert c1 == "prefix "

      {t2, c2, buf2} = HandbeanWeb.WorkspaceLive.strip_think_tags(buf1, "ing continues")
      assert t2 == "ing continues"
      assert c2 == ""

      # Still no close tag — buffer should be empty, state stays :inside
      {t3, c3, _} = HandbeanWeb.WorkspaceLive.strip_think_tags(buf2, " and more")
      assert t3 == " and more"
      assert c3 == ""
    end
  end

  describe "turn folding" do
    test "compute_turns groups entries into a turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "AI response"})})
      rendered = render(view)

      assert rendered =~ "AI response"
      assert rendered =~ "turn-group"
    end

    test "turn header shows for multi-entry turns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "first"})})
      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "second"}, 4)})

      rendered = render(view)
      assert rendered =~ "first"
      assert rendered =~ "second"
      assert rendered =~ "turn-header"
    end

    test "tool calls and assistant belong to same turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.rb"}})}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 50}, 2)}
      )

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "done"}, 3)})

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "done"
    end

    test "turn header includes truncated summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "hello world"})})
      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "bonus"}, 4)})

      rendered = render(view)
      assert rendered =~ "turn-summary"
    end

    test "system error messages belong to their turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "reply"})})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "error", turns: 0, error: "timeout"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "reply"
      assert rendered =~ "timeout"
    end
  end

  describe "tool call folding" do
    test "assistant text after tool call starts a new message segment", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Before tool."})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "README.md"}}, 2)}
      )

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "After tool."}, 3)})

      rendered = render(view)
      before_pos = :binary.match(rendered, "Before tool.") |> elem(0)
      tool_pos = :binary.match(rendered, "README.md") |> elem(0)
      after_pos = :binary.match(rendered, "After tool.") |> elem(0)

      assert before_pos < tool_pos
      assert tool_pos < after_pos
    end

    test "tool call finalizes previous assistant stream item", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Before tool."})})

      assert render(view) =~ ~s(data-streaming="true")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "README.md"}}, 2)}
      )

      rendered = render(view)
      assert rendered =~ ~s(data-final="true")
      assert rendered =~ ~s(data-streaming="false")
    end

    test "multiple consecutive completed tools collapse into one work summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_1",
           tool: "read",
           input: %{file_path: "a.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_1", tool: "read", duration_ms: 30}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_2", tool: "bash", input: %{command: "ls"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_2", tool: "bash", duration_ms: 20}, 4)}
      )

      rendered = render(view)
      assert rendered =~ "tool-work-collapsed"
      assert rendered =~ "tool-work-summary"
      assert rendered =~ "Explored 1 file, 1 command"
      refute rendered =~ "Hide Work"
    end

    test "completed tools stay compact while a later tool in the streak is running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_read",
           tool: "read",
           input: %{file_path: "lib/app.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_read", tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_bash", tool: "bash", input: %{command: "mix test"}},
           3
         )}
      )

      assert has_element?(view, "#tool-work-line-tool-tu_read.tool-work-line", "lib/app.ex")
      assert has_element?(view, "#tool-work-line-tool-tu_bash.tool-work-line", "mix test")
      refute has_element?(view, "#tool-tu_read .tool-status-line")
      refute has_element?(view, "#tool-tu_bash .tool-status-line")
    end

    test "single completed tool call collapses without a group wrapper", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "single.ex"}})}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 10}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "tool-work-collapsed"
      refute rendered =~ "tool-group"
    end

    test "completed tool work can be expanded and hidden again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_a",
           tool: "read",
           input: %{file_path: "x.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_a", tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_b", tool: "write", input: %{content: "abc"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_b", tool: "write", duration_ms: 5}, 4)}
      )

      rendered = render(view)
      assert rendered =~ "Edited 1 file, Explored 1 file"
      refute rendered =~ "Hide Work"

      view
      |> element("#tool-work-summary-tool-tu_a")
      |> render_click()

      expanded = render(view)
      refute expanded =~ "Hide Work"
      assert expanded =~ "tool-work-line-tool-tu_a"
      assert expanded =~ "indent-2"
      assert has_element?(view, "#tool-work-line-tool-tu_a .tool-work-verb", "read")
      assert expanded =~ "x.ex"
      assert expanded =~ "indent-1"
      refute expanded =~ "tool-work-collapsed"
      refute expanded =~ "tool-status-line"

      view
      |> element("#tool-work-summary-tool-tu_a")
      |> render_click()

      collapsed = render(view)
      assert collapsed =~ "Edited 1 file, Explored 1 file"
      refute collapsed =~ "Hide Work"
    end

    test "collapsed tool work defers later file change cards until expanded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_lead",
           tool: "read",
           input: %{file_path: "x.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_lead", tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_change", tool: "edit", input: %{file_path: "y.ex"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_change",
             tool: "edit",
             duration_ms: 5,
             details: %{
               file_path: "y.ex",
               diff_lines: [%{"type" => "ins", "text" => "new line"}]
             }
           },
           4
         )}
      )

      refute has_element?(view, "#chat-file-change-tool-tu_change")

      view
      |> element("#tool-work-summary-tool-tu_lead")
      |> render_click()

      assert has_element?(view, "#chat-file-change-tool-tu_change")
    end
  end

  describe "workspace model policy" do
    @tag :tmp_dir

    test "empty policy allowlist is treated as unrestricted", %{conn: conn} do
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_policy_#{System.unique_integer([:positive])}")

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_policy_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_policy_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      # Empty models.allow.providers means no workspace restriction.
      settings_path = Handbean.WorkspaceSettings.path(tmp_ws_dir)
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        settings_path,
        Jason.encode!(%{
          "models" => %{
            "allow" => %{"providers" => %{}}
          }
        })
      )

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      assert rendered =~ "model-picker"
      assert rendered =~ "stepfun"
      assert rendered =~ "sui2api"
    end

    test "model picker visible when settings file absent", %{conn: conn} do
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_nopolicy_#{System.unique_integer([:positive])}")

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_nopolicy_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_nopolicy_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      # NO settings file written — missing .handbean/settings.jsonc means unrestricted.

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      # With no policy, model picker should be visible
      assert rendered =~ "model-picker"
      assert rendered =~ "stepfun"
      assert rendered =~ "sui2api"
    end

    test "refreshing model picker reloads latest model config", %{conn: conn} do
      tmp_ws_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_refresh_models_#{System.unique_integer([:positive])}"
        )

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_refresh_models_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_refresh_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      initial_render = render(view)
      assert initial_render =~ "Step Router v1 (StepFun)"
      refute initial_render =~ "GPT-5.4 Mini"

      File.write!(
        models_path,
        Jason.encode!(%{
          "defaultProvider" => "stepfun",
          "defaultModel" => "gpt-5.4-mini",
          "providers" => %{
            "stepfun" => %{
              "baseUrl" => "https://api.stepfun.com/step_plan/v1",
              "api" => "stepfun-step-plan",
              "provider" => "stepfun",
              "models" => [
                %{"id" => "step-router-v1", "name" => "Step Router v1 (StepFun)"},
                %{"id" => "gpt-5.4-mini", "name" => "GPT-5.4 Mini"}
              ]
            },
            "sui2api" => %{
              "baseUrl" => "https://example.test/v1",
              "api" => "openai-responses",
              "models" => [
                %{"id" => "gpt-5.5", "name" => "GPT-5.5"}
              ]
            }
          }
        })
      )

      view
      |> element("#model-picker")
      |> render_click()

      refreshed = render(view)
      assert refreshed =~ "GPT-5.4 Mini"
    end

    test "missing global model config is seeded on first visit", %{conn: conn} do
      tmp_ws_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_missing_models_#{System.unique_integer([:positive])}"
        )

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_missing_models_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_missing_#{System.unique_integer([:positive])}.json"
        )

      System.put_env("HANDBEAN_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAN_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)
      Handbean.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAN_WORKSPACE")
        System.delete_env("HANDBEAN_WORKSPACES_FILE")
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
      end)

      refute File.exists?(models_path)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      assert File.exists?(models_path)
      assert rendered =~ "model-picker"
      refute rendered =~ "Configure models before sending"
    end
  end

  describe "reasoning selector" do
    test "renders beside the input controls for reasoning-capable models", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_reasoning_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#reasoning-picker")
      assert has_element?(view, "#reasoning-picker option[value='medium']")
      assert has_element?(view, "#reasoning-picker option[value='high']")
      refute has_element?(view, "#reasoning-picker option[value='xhigh']")
    end

    test "selecting reasoning updates the selected value", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_select_reasoning_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      view
      |> element("#reasoning-picker")
      |> render_change(%{"reasoning" => "high"})

      assert has_element?(view, "#reasoning-picker option[value='high']")
      assert render(view) =~ "reasoning-picker"
    end

    test "form-level composer_drop keeps a High reasoning pick", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_composer_drop_reasoning_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      # Native <select> inside #composer fires the form phx-change, not only
      # the picker's own select_reasoning event.
      view
      |> element("#composer")
      |> render_change(%{"reasoning" => "high", "model" => "stepfun/step-router-v1"})

      html = render(view)
      assert html =~ ~s(option selected value="high") or html =~ ~s(value="high" selected)
    end

    test "model and reasoning stay visible as mid-conversation controls", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_mid_thread_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})
      html = render(view)

      assert html =~ "composer-turn-controls"
      assert has_element?(view, "#model-picker")
      assert has_element?(view, "#reasoning-picker")
      refute html =~ "This conversation"
      refute html =~ "Next message"
      refute html =~ "本对话使用"
      refute html =~ "下一条使用"
    end
  end

  describe "tool permissions menu" do
    test "toggles permission menu and selects new permission mode", %{conn: conn} do
      {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      html = render(view)

      # Initial state: menu should not be visible
      refute html =~ "permission-dropdown-menu"
      assert has_element?(view, "button[phx-click='toggle_permission_menu']")

      # Click the permission pill to toggle menu
      view |> element("button[phx-click='toggle_permission_menu']") |> render_click()
      assert render(view) =~ "permission-dropdown-menu"

      refute has_element?(view, "button[phx-value-mode='auto']")
      assert has_element?(view, "button[phx-value-mode='prompt']")
      assert has_element?(view, "button[phx-value-mode='yolo']")

      view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='auto_review']")
      |> render_click()

      refute render(view) =~ "permission-dropdown-menu"
      assert render(view) =~ "智能审批"

      assert {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert get_in(settings, ["tools", "default_mode"]) == "auto"
      assert get_in(settings, ["tools", "approvals_reviewer"]) == "auto_review"
    end

    test "smart approval replaces yolo policy and safe mode restores human review", %{conn: conn} do
      {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]
      settings_path = Handbean.WorkspaceSettings.path(workspace_root)
      original = if File.exists?(settings_path), do: File.read!(settings_path), else: nil

      on_exit(fn ->
        if is_binary(original), do: File.write!(settings_path, original)
      end)

      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(settings_path, """
      {
        // keep me
        "tools": {
          "default_mode": "yolo",
          "allow": ["read"]
        }
      }
      """)

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      view |> element("button[phx-click='toggle_permission_menu']") |> render_click()

      view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='auto_review']")
      |> render_click()

      html = render(view)
      assert html =~ "智能审批"
      assert html =~ "只自动复审本来要问的操作，不扩大权限。"
      refute html =~ "permission-dropdown-menu"

      content = File.read!(settings_path)
      assert content =~ "// keep me"
      assert content =~ "\"default_mode\": \"auto\""
      assert content =~ "\"allow\": [\"read\"]"
      assert content =~ "\"approvals_reviewer\": \"auto_review\""

      {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert get_in(settings, ["tools", "default_mode"]) == "auto"
      assert get_in(settings, ["tools", "approvals_reviewer"]) == "auto_review"

      view |> element("button[phx-click='toggle_permission_menu']") |> render_click()

      view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='prompt']")
      |> render_click()

      html = render(view)
      assert html =~ "安全模式" or html =~ "Safe Mode"
      refute html =~ "智能审批"

      content = File.read!(settings_path)
      assert content =~ "// keep me"
      assert content =~ "\"default_mode\": \"prompt\""
      {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert get_in(settings, ["tools", "default_mode"]) == "prompt"
      assert get_in(settings, ["tools", "approvals_reviewer"]) == "user"
      assert get_in(settings, ["tools", "allow"]) == ["read"]
    end

    for action <- ["approve_all_tools", "deny_all_tools"] do
      @approval_action action
      test "#{action} defaults to once without saving workspace rules", %{conn: conn} do
        {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()
        :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace["path"], :prompt)
        {:ok, before_settings} = Handbean.WorkspaceSettings.load(workspace["path"])
        {:ok, view, _html} = live(conn, "/")
        create_default_conversation(view)

        pending = %{
          type: :tool_approval,
          action_requests: [
            %{
              tool_call_id: "once-1",
              tool_name: "bash",
              arguments: %{"command" => "git status --short"},
              suggested_pattern: "bash(git status*)"
            }
          ]
        }

        send(view.pid, {:agent_event, agent_event(:tool_approval_requested, pending, 1)})

        view
        |> element(
          "#tool-approval-overlay button[phx-click='#{@approval_action}']:not([phx-value-remember])"
        )
        |> render_click()

        refute has_element?(view, "#tool-approval-overlay")
        assert {:ok, ^before_settings} = Handbean.WorkspaceSettings.load(workspace["path"])
      end
    end

    test "always-allow persists a matcher pattern and skips the next HITL", %{conn: conn} do
      {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]

      :ok = Handbean.WorkspaceSettings.update_permission_mode(workspace_root, :prompt)

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      pending = %{
        type: :tool_approval,
        action_requests: [
          %{
            tool_call_id: "b1",
            tool_name: "bash",
            arguments: %{"command" => "git status --short"},
            suggested_pattern: "bash(git status*)"
          }
        ]
      }

      send(view.pid, {:agent_event, agent_event(:tool_approval_requested, pending, 1)})
      html = render(view)

      assert html =~ "tool-approval-overlay"
      assert html =~ "Always allow"
      assert html =~ "bash(git status*)"

      assert has_element?(
               view,
               "#approval-more-options:not([open]) summary",
               "More approval options"
             )

      assert has_element?(view, "#approval-more-options button[phx-value-remember='session']")
      assert has_element?(view, "#approval-more-options button[phx-value-remember='always']")
      assert has_element?(view, "#approval-more-options li", "bash(git status*)")

      assert has_element?(
               view,
               "#tool-approval-overlay button[phx-click='approve_all_tools']:not([phx-value-remember])",
               "Allow once"
             )

      assert has_element?(
               view,
               "#tool-approval-overlay button[phx-click='deny_all_tools']",
               "Deny"
             )

      refute has_element?(
               view,
               "#tool-approval-overlay button[phx-click='deny_all_tools'][phx-value-remember]"
             )

      view
      |> element("button[phx-click='approve_all_tools'][phx-value-remember='always']")
      |> render_click()

      refute render(view) =~ "tool-approval-overlay"

      assert {:ok, settings} = Handbean.WorkspaceSettings.load(workspace_root)
      assert "bash(git status*)" in (get_in(settings, ["tools", "allow"]) || [])

      policy = Handbean.Permissions.ToolPolicy.from_workspace(workspace_root)

      assert Handbean.Permissions.ToolPolicy.decision(policy, %{
               name: "bash",
               input: %{"command" => "git status"}
             }) == :auto

      assert Handbean.Permissions.ToolPolicy.decision(policy, %{
               name: "bash",
               input: %{"command" => "rm -rf tmp"}
             }) == :prompt
    end
  end

  describe "settings panel" do
    test "shows memory processing parameters without a global enable switch", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_settings_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      result = view |> element("#open-settings") |> render_click()
      {:ok, settings_view, html} = follow_redirect(result, conn)

      assert html =~ "Model / AI"
      assert has_element?(settings_view, "select[name='om_model']")
      refute has_element?(settings_view, "input[name='om_enabled']")
    end

    test "updates default model and reasoning settings without crashing", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_settings_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAN_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAN_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      # Open settings panel
      result = view |> element("#open-settings") |> render_click()
      {:ok, settings_view, _html} = follow_redirect(result, conn)

      # Change default model
      html =
        settings_view
        |> element("select[name='default_model']")
        |> render_change(%{"default_model" => "stepfun/step-router-v1"})

      # The default_model option is selected
      assert html =~ "selected"

      # Change reasoning
      html =
        settings_view
        |> element("select[name='reasoning']")
        |> render_change(%{"reasoning" => "high"})

      assert html =~ "selected"
    end
  end

  describe "skill autocomplete" do
    setup do
      on_exit(fn ->
        home_skills = Path.join([System.get_env("HOME") || "", ".handbean", "skills"])

        if File.dir?(home_skills) do
          home_skills
          |> File.ls!()
          |> Enum.each(fn name ->
            if String.starts_with?(name, "autocomplete-") or name in ["other-skill", "other-code"] do
              File.rm_rf!(Path.join(home_skills, name))
            end
          end)
        end
      end)

      :ok
    end

    defp create_test_skill(name, description) do
      skill_dir =
        Path.join([System.get_env("HOME") || Handbean.Home.path(), ".handbean", "skills", name])

      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        """
        ---
        name: #{name}
        description: #{description}
        ---

        Test skill body.
        """
      )

      :ok
    end

    test "typing / shows skill suggestions dropdown", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha skill for testing")
      create_test_skill("autocomplete-beta", "Beta skill for testing")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/"})

      # The dropdown should appear with both skills
      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
    end

    test "typing /autocomplete filters to matching skills", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")
      create_test_skill("autocomplete-beta", "Beta")
      create_test_skill("other-skill", "Other")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/autocomplete"})

      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
      refute html =~ "other-skill"
    end

    test "typing /xyz with no match shows no suggestions", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/xyz"})

      # No dropdown when no matches
      refute html =~ "skill-suggestions"
    end

    test "typing plain text without / shows no suggestions", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "hello world"})

      refute html =~ "skill-suggestions"
    end

    test "selecting a skill suggestion replaces input with /skill:name", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha skill for testing")

      {:ok, view, _html} = live(conn, "/")

      # First, simulate typing "/auto"
      _html = render_keyup(view, "update_input", %{"value" => "/auto"})

      # Then select the suggestion
      html =
        view
        |> element(
          "button[phx-click='select_skill_suggestion'][phx-value-name='autocomplete-alpha']"
        )
        |> render_click()

      # Input should now contain /skill:autocomplete-alpha
      assert html =~ "/skill:autocomplete-alpha"
      # Dropdown should be dismissed
      refute html =~ "skill-suggestions"
    end

    test "dismissing skill suggestions clears the dropdown", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      _html = render_keyup(view, "update_input", %{"value" => "/"})

      html = render_click(view, "dismiss_skill_suggestions", %{})

      refute html =~ "skill-suggestions"
    end

    test "typing /skill: filters by skill name after prefix", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")
      create_test_skill("autocomplete-beta", "Beta")
      create_test_skill("other-code", "Code")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/skill:auto"})

      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
      refute html =~ "other-code"
    end
  end

  describe "conversation navigator" do
    test "renders delegation reports as collapsed cards without wrapper JSON or user navigation",
         %{
           conn: conn
         } do
      completed =
        "Background subagent report for child_conversation_id child-research (requires your review; use task_status to follow up):\n" <>
          Handbean.JSON.encode!(%{
            status: :completed,
            subagent_type: "researcher",
            child_conversation_id: "child-research",
            child_run_id: "run-research",
            usage: %{
              input_tokens: 5_481,
              output_tokens: 827,
              cache_read_input_tokens: 300
            },
            report: "## Finding\n\nOnly the **report** is rendered."
          })

      max_turns =
        "Background subagent report for child_conversation_id child-max (requires your review; use task_status to follow up):\n" <>
          Handbean.JSON.encode!(%{
            status: :max_turns,
            subagent_type: "researcher",
            child_conversation_id: "child-max",
            usage: %{input_tokens: "1200", output_tokens: 42},
            report: "Reached the turn limit with a usable result."
          })

      failed =
        "Background subagent report for child_conversation_id child-error (requires your review; use task_status to follow up):\n" <>
          Handbean.JSON.encode!(%{
            status: :error,
            subagent_type: "advisor",
            child_conversation_id: "child-error",
            error: "Provider unavailable"
          })

      legacy =
        "Background subagent report for child_conversation_id child-legacy (requires your review):\n" <>
          Handbean.JSON.encode!(%{report: "Legacy report body"})

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-subagent-reports",
          title: "Subagent reports",
          timeline: [
            %{
              "id" => "report-completed",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => completed
            },
            %{
              "id" => "nav-user-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "First real user message"
            },
            %{
              "id" => "report-max",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => max_turns
            },
            %{
              "id" => "report-error",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => failed
            },
            %{
              "id" => "report-legacy",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => legacy
            },
            %{
              "id" => "report-malformed",
              "content_type" => "user_msg",
              "role" => "user",
              "source" => "delegation",
              "channel" => "internal",
              "content" => "not valid report JSON"
            },
            %{
              "id" => "nav-user-2",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "Second real user message"
            }
          ]
        )

      {:ok, view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html |> Floki.parse_fragment!() |> Floki.find("[data-subagent-report]") |> length() ==
               5

      assert has_element?(
               view,
               "[data-subagent-report][data-status='completed'] details:not([open])"
             )

      assert has_element?(view, "[data-subagent-report][data-status='max_turns']")

      assert has_element?(
               view,
               "[data-subagent-report][data-status='error']",
               "Provider unavailable"
             )

      assert has_element?(
               view,
               "[data-subagent-report][data-status='unknown']",
               "Legacy report body"
             )

      assert has_element?(
               view,
               "#subagent-report-report-malformed-unknown-0",
               "Report unavailable"
             )

      assert has_element?(
               view,
               "[data-subagent-report] [data-source*='Only the **report** is rendered.']"
             )

      assert has_element?(view, "[data-subagent-report]", "Input 5.5K")
      assert has_element?(view, "[data-subagent-report]", "Output 827")
      assert has_element?(view, "[data-subagent-report] [data-copy='child-research']")
      refute html =~ "Background subagent report"
      refute html =~ "child_run_id"
      refute has_element?(view, "[data-user-msg='report-completed']")
      refute has_element?(view, "[data-user-msg='report-max']")
      refute has_element?(view, "[data-user-msg='report-malformed']")
      refute has_element?(view, "[data-target-id='report-completed']")
      assert has_element?(view, "[data-target-id='nav-user-1']")
      assert has_element?(view, "[data-target-id='nav-user-2']")
      assert has_element?(view, "#turn-header", "First real user message")

      html =
        view
        |> element(
          "#subagent-report-report-completed-child-research-0 .subagent-report-follow-up"
        )
        |> render_click()

      assert html =~ "@child-research "
    end

    test "lists only user messages next to the scroll-to-bottom control", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-nav-many",
          title: "Nav many",
          timeline: [
            %{
              "id" => "nav-user-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "先看第一轮用户问题"
            },
            %{
              "id" => "nav-assistant-1",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "助手不该出现在导航"
            },
            %{
              "id" => "nav-tool-1",
              "content_type" => "tool",
              "tool_name" => "read",
              "content" => "README.md"
            },
            %{
              "id" => "nav-user-2",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "再问第二轮"
            }
          ]
        )

      {:ok, _view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ ~s(id="conversation-nav")
      assert html =~ ~s(data-conversation-nav-toggle)
      assert html =~ ~s(id="mobile-fab")
      assert html =~ ~s(data-target-id="nav-user-1")
      assert html =~ ~s(data-target-id="nav-user-2")
      assert html =~ "先看第一轮用户问题"
      assert html =~ "再问第二轮"
      refute html =~ ~s(data-target-id="nav-assistant-1")
      refute html =~ ~s(data-target-id="nav-tool-1")
    end

    test "hides internal model compaction checkpoints", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-hidden-compaction",
          title: "Hidden compaction",
          timeline: [
            %{
              "id" => "compaction-hidden-1",
              "content_type" => "model_compaction",
              "message_type" => "internal",
              "role" => "internal",
              "summary" => "PRIVATE-COMPACTION-SUMMARY"
            },
            %{
              "id" => "visible-user",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "Visible request"
            }
          ]
        )

      {:ok, view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ "Visible request"
      refute html =~ "PRIVATE-COMPACTION-SUMMARY"
      refute has_element?(view, "#timeline-compaction-hidden-1")
      refute has_element?(view, "[data-target-id='compaction-hidden-1']")
    end

    test "hides the hamburger when there are fewer than two user turns", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbean.ConversationStore.create("default",
          id: "conv-nav-short",
          title: "Nav short",
          timeline: [
            %{
              "id" => "nav-only-user",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "只有一条"
            },
            %{
              "id" => "nav-only-assistant",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "一条回复"
            }
          ]
        )

      {:ok, _view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ ~s(id="conversation-nav")
      assert html =~ ~s(id="mobile-fab")
      refute html =~ ~s(data-conversation-nav-toggle)
      refute html =~ ~s(data-target-id="nav-only-user")
    end
  end

  describe "free chat send" do
    test "sending in a new free chat replies before the run starts", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, view, _html} = live(conn, "/")

      view |> element("#new-free-conversation") |> render_click()

      assert render(view) =~ "Chats"

      html =
        view
        |> form("#composer", %{message: "hello free chat"})
        |> render_submit()

      assert html =~ "hello free chat"
      assert render(view) =~ "hello free chat"
      refute render(view) =~ "Message not delivered"
    end

    test "free chats can be renamed, archived, and restored", %{conn: conn} do
      isolate_conversation_home!()
      {:ok, conv} = Handbean.ConversationStore.create_free(title: "Free notes")

      {:ok, view, _html} = live(conn, "/c/#{conv["id"]}")

      assert has_element?(view, "#conversation-menu-free-#{conv["id"]}")
      view |> element("#conversation-menu-free-#{conv["id"]}") |> render_click()
      assert has_element?(view, "#conversation-action-rename-free-#{conv["id"]}", "Rename")
      assert has_element?(view, "#conversation-action-archive-free-#{conv["id"]}", "Archive")

      view |> element("#conversation-action-rename-free-#{conv["id"]}") |> render_click()
      assert has_element?(view, "#rename-conversation-dialog")

      view
      |> form("#rename-conversation-dialog", %{title: "Renamed free"})
      |> render_submit()

      assert has_element?(view, "#free-conversation-#{conv["id"]}", "Renamed free")
      {:ok, renamed} = Handbean.ConversationStore.get_metadata(conv["id"])
      assert renamed["title"] == "Renamed free"
      assert renamed["title_source"] == "manual"

      view |> element("#conversation-menu-free-#{conv["id"]}") |> render_click()
      view |> element("#conversation-action-archive-free-#{conv["id"]}") |> render_click()

      refute has_element?(view, "#free-conversation-#{conv["id"]}")
      {:ok, archived} = Handbean.ConversationStore.get_metadata(conv["id"])
      assert is_binary(archived["archived_at"])

      view |> element("button.workspace-header[phx-click='toggle_archive']") |> render_click()

      assert has_element?(
               view,
               "button[phx-click='unarchive_conversation'][phx-value-id='#{conv["id"]}']"
             )

      view
      |> element("button[phx-click='unarchive_conversation'][phx-value-id='#{conv["id"]}']")
      |> render_click()

      assert has_element?(view, "#free-conversation-#{conv["id"]}", "Renamed free")
    end

    test "free chats can be deleted after confirmation and switch to a remaining chat", %{
      conn: conn
    } do
      isolate_conversation_home!()
      {:ok, doomed} = Handbean.ConversationStore.create_free(title: "Delete me")
      {:ok, kept} = Handbean.ConversationStore.create_free(title: "Keep me")

      {:ok, view, _html} = live(conn, "/c/#{doomed["id"]}")

      view |> element("#conversation-menu-free-#{doomed["id"]}") |> render_click()

      view
      |> element("#conversation-action-delete-free-#{doomed["id"]}")
      |> render_click()

      assert has_element?(view, "#delete-conversation-dialog")
      assert has_element?(view, "#confirm-delete-conversation")

      view |> element("#confirm-delete-conversation") |> render_click()

      assert_patch(view, "/c/#{kept["id"]}")
      refute has_element?(view, "#free-conversation-#{doomed["id"]}")
      refute Handbean.ConversationStore.exists?(doomed["id"])

      assert %Handbean.Storage.Conversation{status: "pending_delete"} =
               Handbean.Repo.get(Handbean.Storage.Conversation, doomed["id"])
    end

    test "mobile conversation info exposes the same confirmed delete flow", %{conn: conn} do
      isolate_conversation_home!()
      {:ok, conversation} = Handbean.ConversationStore.create_free(title: "Mobile delete")
      {:ok, view, _html} = live(conn, "/c/#{conversation["id"]}")

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='settings']")
      |> render_click()

      assert has_element?(view, "#mobile-delete-conversation")
      view |> element("#mobile-delete-conversation") |> render_click()
      assert has_element?(view, "#delete-conversation-dialog")
    end
  end
end
