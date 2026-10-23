defmodule HandbeanWeb.WorkspaceLiveCase do
  use ExUnit.CaseTemplate

  @endpoint HandbeanWeb.Endpoint

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest, except: [live: 2]

  alias Handbean.PubSub.AgentEvent

  using do
    quote do
      use HandbeanWeb.ConnCase, async: false

      import Phoenix.LiveViewTest, except: [live: 2]
      import ExUnit.CaptureLog
      import HandbeanWeb.WorkspaceLiveCase

      alias Handbean.PubSub.AgentEvent
      alias HandbeanWeb.WorkspaceLiveCase.CleanupProvider
      alias HandbeanWeb.WorkspaceLiveCase.FileManagerStub

      setup context do
        HandbeanWeb.WorkspaceLiveCase.setup_workspace_live(context)
      end
    end
  end

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

  def setup_workspace_live(_context) do
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

  def live(conn, path) do
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

  def git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  def init_git_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Handbean Test"])
    File.write!(Path.join(path, "README.md"), "main")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "fixture"])
  end

  # ── Helper: build an AgentEvent for tests ──
  def send_recorded_edit(view, tool_use_id, file_path, change) do
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

  def change_event_details(change) do
    Handbean.ChangeSnapshot.result_details(change, %{
      conversation_id: "workspace-live-revert-test"
    })
  end

  def agent_event(kind, payload, seq \\ 1) do
    agent_event(kind, payload, seq, "s:1")
  end

  def agent_event(kind, payload, seq, topic) do
    %AgentEvent{
      kind: kind,
      payload: payload,
      seq: seq,
      topic: topic,
      ts_ms: 0
    }
  end

  def session_id_from_html(html) do
    ids =
      Regex.scan(~r/data-session-id="([^"]*)"/, html, capture: :all_but_first)
      |> List.flatten()

    Enum.find(ids, &(&1 != "")) || List.last(ids) ||
      raise "no data-session-id in html"
  end

  def choose_new_conversation_project(view, workspace_id, message \\ "Start conversation") do
    before =
      Handbean.ConversationStore.list_for_workspace(workspace_id)
      |> MapSet.new(& &1["id"])

    view
    |> element("#new-conversation-picker-toggle")
    |> render_click()

    if not has_element?(view, "#new-conversation-composer") do
      view
      |> element("#new-conversation-picker-toggle")
      |> render_click()
    end

    if not has_element?(view, "#new-conversation-project-#{workspace_id}") do
      view
      |> element(".new-conversation-chip[aria-controls='new-conversation-projects']")
      |> render_click()
    end

    if has_element?(view, "#new-conversation-project-#{workspace_id}") do
      view
      |> element("#new-conversation-project-#{workspace_id}")
      |> render_click()
    end

    [draft_id] =
      view
      |> render()
      |> then(&Regex.run(~r/name="draft_id" value="([^"]+)"/, &1, capture: :all_but_first))

    view
    |> form("#new-conversation-composer", %{"draft_id" => draft_id, "message" => message})
    |> render_submit()

    Handbean.ConversationStore.list_for_workspace(workspace_id)
    |> Enum.find_value(fn conversation ->
      if MapSet.member?(before, conversation["id"]), do: nil, else: conversation["id"]
    end)
  end

  def create_default_conversation(view) do
    {:ok, conversation} = Handbean.ConversationStore.create("default", title: "New chat")

    render_click(view, "select_conversation", %{
      "id" => conversation["id"],
      "ws_id" => "default"
    })

    conversation["id"]
  end

  def isolate_conversation_home! do
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

  def stop_test_runtime!(tracker) do
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

  def stop_and_wait(pid, stop) when is_pid(pid) do
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

  def wait_for_process(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end

  def safe_rm_test_rune!(home_dir) do
    target = Path.expand(Path.join(home_dir, ".handbean"))
    tmp_root = Path.expand(System.tmp_dir!())

    if String.starts_with?(target, tmp_root) do
      File.rm_rf!(target)
    else
      raise "[PathSafety] refusing to delete non-temp .handbean/: #{target} (tmp_root=#{tmp_root})"
    end
  end

  def write_test_models_config(path) do
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
                "reasoningLevels" => ["minimal", "medium", "high"],
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

  def configure_test_models! do
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
end
