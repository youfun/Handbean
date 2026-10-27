defmodule HandbeanProbe.HomeScreenSchedulesTest do
  use Mob.ScreenCase, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  import HandbeanProbe.ScreenSettle

  alias Handbean.Schedule.{Entry, Run, Store}
  alias HandbeanProbe.{HomeScreen, NativeSchedules}

  # The mobile host has no tz database, so zone validation only accepts the
  # built-in UTC zone (same constraint the on-device runtime has).
  @zone "Etc/UTC"
  @render_extras [:icon, :settings_select, :settings_button]

  setup do
    Handbean.Repo.delete_all(Run)
    Handbean.Repo.delete_all(Entry)
    HandbeanProbe.TestDB.reset_conversations!()

    dir = Path.join(System.tmp_dir!(), "native_schedules_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    previous_locale = HandbeanProbe.Gettext.locale()

    HandbeanProbe.NativePlatform.put!(:android)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})
    # Mount reads the persisted UI locale and applies it to this process.
    # Gettext.put_locale/2 alone does not survive HomeScreen.mount/3.
    :ok = Handbean.Settings.UI.save_locale("en")
    HandbeanProbe.Gettext.apply("en")

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      HandbeanProbe.RuntimeCleanup.stop!()

      _ = Handbean.Settings.UI.save_locale(previous_locale)
      HandbeanProbe.Gettext.apply(previous_locale)
      Application.delete_env(:handbean, :schedule_now)

      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      if previous_platform,
        do: Application.put_env(:handbean_probe, :native_platform, previous_platform),
        else: Application.delete_env(:handbean_probe, :native_platform)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      _ = File.rm_rf(dir)
    end)

    %{view: settle(mount_screen(HomeScreen)), dir: dir}
  end

  # ── pure projection and rendering ──

  test "renders cards with status, meta, next run, and row actions" do
    now = ~U[2026-10-21 08:00:00Z]

    active = entry(%{id: "sched-active", conversation_id: "conv-active"})

    paused =
      entry(%{
        id: "sched-paused",
        conversation_id: "conv-paused",
        name: "Evening report",
        status: "paused",
        next_run_at: nil
      })

    state =
      NativeSchedules.new()
      |> NativeSchedules.loaded(
        {:ok,
         loaded_data([active, paused], now,
           titles: %{"conv-active" => "Morning chat", "conv-paused" => "Evening chat"}
         )}
      )

    tree = NativeSchedules.render(state)
    blob = flatten_text(tree)

    assert blob =~ gettext("Scheduled tasks")
    assert blob =~ "Morning report"
    assert blob =~ gettext("Enabled")
    assert blob =~ "Morning chat"
    assert blob =~ "Handbean"
    assert blob =~ gettext("Next: %{at}", at: "")
    assert tap?(tree, {:schedule_open, "sched-active"})
    assert tap?(tree, {:schedule_pause, "sched-active"})
    assert tap?(tree, {:schedule_run_now, "sched-active"})
    assert tap?(tree, {:schedule_revise, "sched-active"})
    assert tap?(tree, {:schedule_ask_delete, "sched-active"})

    assert blob =~ "Evening report"
    assert blob =~ gettext("Paused")
    assert tap?(tree, {:schedule_resume, "sched-paused"})
    refute tap?(tree, {:schedule_pause, "sched-paused"})
  end

  test "marks a failed last run and expands a long instruction" do
    now = ~U[2026-10-21 08:00:00Z]
    at = DateTime.add(now, -3_600, :second)

    failed =
      struct!(Run,
        id: "run-failed",
        schedule_id: "sched-active",
        kind: "scheduled",
        status: "failed",
        slot_at: at,
        inserted_at: at,
        updated_at: at
      )

    long_instruction = String.duplicate("check the build and the tests. ", 10)
    entry = entry(%{id: "sched-active", instruction: long_instruction})

    state =
      NativeSchedules.new()
      |> NativeSchedules.loaded(
        {:ok, loaded_data([entry], now, runs: %{"sched-active" => [failed]})}
      )

    tree = NativeSchedules.render(state)
    assert flatten_text(tree) =~ gettext("Failed")
    assert tap?(tree, {:schedule_toggle_instruction, "sched-active"})
    assert flatten_text(tree) =~ gettext("Expand")

    expanded = NativeSchedules.toggle_instruction(state, "sched-active")
    assert flatten_text(NativeSchedules.render(expanded)) =~ gettext("Collapse")
  end

  test "renders the empty state and the delete confirmation sheet" do
    now = ~U[2026-10-21 08:00:00Z]

    empty =
      NativeSchedules.new()
      |> NativeSchedules.loaded({:ok, loaded_data([], now)})

    assert flatten_text(NativeSchedules.render(empty)) =~ gettext("No scheduled tasks yet")

    task = entry(%{})

    confirming =
      empty
      |> NativeSchedules.loaded({:ok, loaded_data([task], now)})
      |> NativeSchedules.ask_delete(task.id)

    tree = NativeSchedules.render(confirming)

    assert flatten_text(tree) =~
             gettext("Delete scheduled task \"%{name}\"?", name: "Morning report")

    assert tap?(tree, :schedule_delete)
    assert tap?(tree, :schedule_dismiss_confirm)
  end

  # ── screen behavior ──

  test "opens the task page, lists schedules, and reloads when a row changes", %{view: view} do
    {:ok, _conversation} =
      Handbean.ConversationStore.create("default", id: "sched-conv-1", title: "Morning chat")

    task = create_schedule("default", "sched-conv-1", name: "Morning report")

    view = info(view, {:tap, {:page, :schedules}})
    assert assigns(view).page == :schedules
    refute assigns(view).schedules.loading?

    assert text(view) =~ "Morning report"
    assert tap_text(view, {:schedule_open, task.id}) == "Morning chat"
    assert_renderable(view, extra: @render_extras)

    view = info(view, {:schedule_changed, "sched-conv-1"})
    refute assigns(view).schedules.loading?
    assert Enum.any?(assigns(view).schedules.items, &(&1.id == task.id))
    assert text(view) =~ "Morning report"
  end

  test "pauses and resumes a schedule from the task page", %{view: view} do
    {:ok, _conversation} =
      Handbean.ConversationStore.create("default", id: "sched-conv-2", title: "Morning chat")

    task = create_schedule("default", "sched-conv-2", name: "Morning report")
    view = info(view, {:tap, {:page, :schedules}})

    view = info(view, {:tap, {:schedule_pause, task.id}})
    assert {:ok, paused} = Store.get(task.id)
    assert paused.status == "paused"
    refute assigns(view).schedules.busy?
    assert text(view) =~ gettext("Paused")

    view = info(view, {:tap, {:schedule_resume, task.id}})
    assert {:ok, resumed} = Store.get(task.id)
    assert resumed.status == "active"
    assert resumed.next_run_at
    assert text(view) =~ gettext("Enabled")
  end

  test "deletes a schedule after confirmation", %{view: view} do
    {:ok, _conversation} =
      Handbean.ConversationStore.create("default", id: "sched-conv-3", title: "Morning chat")

    task = create_schedule("default", "sched-conv-3", name: "Morning report")
    view = info(view, {:tap, {:page, :schedules}})

    view = info(view, {:tap, {:schedule_ask_delete, task.id}})
    assert assigns(view).schedules.confirming == task.id
    assert text(view) =~ gettext("Delete scheduled task")

    view = info(view, {:tap, :schedule_dismiss_confirm})
    assert assigns(view).schedules.confirming == nil
    assert {:ok, _entry} = Store.get(task.id)

    view = info(view, {:tap, {:schedule_ask_delete, task.id}})
    view = info(view, {:tap, :schedule_delete})
    assert {:error, :not_found} = Store.get(task.id)
    assert assigns(view).schedules.confirming == nil
    assert text(view) =~ gettext("No scheduled tasks yet")
  end

  test "run now claims a manual run and reports it queued", %{view: view} do
    {:ok, _conversation} =
      Handbean.ConversationStore.create("default", id: "sched-conv-4", title: "Morning chat")

    task = create_schedule("default", "sched-conv-4", name: "Morning report")
    view = info(view, {:tap, {:page, :schedules}})

    view = info(view, {:tap, {:schedule_run_now, task.id}})

    assert HandbeanProbe.HomeScreen.Notice.text(assigns(view).notice) ==
             gettext("Queued to run now")

    # No model is configured in this host, so the dispatch records a skip
    # instead of starting an agent run.
    assert Enum.any?(
             Store.recent_runs(task.id),
             &(&1.kind == "manual" and &1.status == "skipped" and &1.reason == "model_not_allowed")
           )

    assert text(view) =~ gettext("Skipped")
  end

  test "opens the schedule conversation, switching workspace when needed", %{
    view: view,
    dir: dir
  } do
    path_b = Path.join(dir, "workspace_b")
    File.mkdir_p!(path_b)
    {:ok, workspace_b} = Handbean.WorkspaceStore.add(path_b, name: "Project B")

    {:ok, _conversation} =
      Handbean.ConversationStore.create(workspace_b["id"], id: "sched-conv-b", title: "Beta chat")

    task = create_schedule(workspace_b["id"], "sched-conv-b", name: "Beta report")

    assert assigns(view).workspace["id"] == "default"

    view = info(view, {:tap, {:page, :schedules}})
    assert text(view) =~ "Beta report"
    assert text(view) =~ "Project B"

    view = info(view, {:tap, {:schedule_open, task.id}})
    assert assigns(view).page == :chat
    assert assigns(view).workspace["id"] == workspace_b["id"]
    assert assigns(view).chat.conversation["id"] == "sched-conv-b"
  end

  test "revise opens the conversation and prefills the draft", %{view: view} do
    {:ok, _conversation} =
      Handbean.ConversationStore.create("default", id: "sched-conv-5", title: "Morning chat")

    task = create_schedule("default", "sched-conv-5", name: "Morning report")
    view = info(view, {:tap, {:page, :schedules}})

    view = info(view, {:tap, {:schedule_revise, task.id}})
    assert assigns(view).page == :chat
    assert assigns(view).chat.conversation["id"] == "sched-conv-5"
    assert assigns(view).draft == gettext("Revise \"%{name}\":", name: "Morning report")
  end

  test "schedule events are ignored while another page is open", %{view: view} do
    {:ok, _conversation} =
      Handbean.ConversationStore.create("default", id: "sched-conv-6", title: "Morning chat")

    task = create_schedule("default", "sched-conv-6", name: "Morning report")

    # Still on the chat page: page-scoped taps must not reach the controller.
    view = info(view, {:tap, {:schedule_pause, task.id}})
    assert {:ok, entry} = Store.get(task.id)
    assert entry.status == "active"

    view = info(view, {:tap, {:page, :schedules}})
    view = info(view, {:tap, {:page, :chat}})
    assert text(view) =~ gettext("Start a new conversation")
  end

  # ── helpers ──

  # Dispatch one message, then deliver every off-screen task reply it caused.
  defp info(view, message) do
    {:noreply, socket} = HomeScreen.handle_info(message, view.socket)
    settle(%{view | socket: socket})
  end

  defp create_schedule(workspace_id, conversation_id, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    Application.put_env(:handbean, :schedule_now, fn -> now end)

    {:ok, entry} =
      Store.create(%{
        workspace_id: workspace_id,
        conversation_id: conversation_id,
        name: Keyword.get(opts, :name, "Morning report"),
        instruction: Keyword.get(opts, :instruction, "Summarize the project"),
        rule: Keyword.get(opts, :rule, %{"kind" => "interval", "every_minutes" => 30}),
        time_zone: Keyword.get(opts, :time_zone, @zone),
        model: Keyword.get(opts, :model, "fake/model"),
        created_by: "user"
      })

    entry
  end

  defp entry(overrides) do
    now = ~U[2026-10-21 08:00:00Z]

    struct!(
      Entry,
      Map.merge(
        %{
          id: "sched-entry",
          workspace_id: "default",
          conversation_id: "conv-entry",
          name: "Morning report",
          instruction: "Summarize the project",
          rule: %{"kind" => "interval", "every_minutes" => 30},
          time_zone: @zone,
          model: "fake/model",
          status: "active",
          next_run_at: DateTime.add(now, 1_800, :second),
          version: 1,
          created_by: "user",
          inserted_at: now,
          updated_at: now
        },
        overrides
      )
    )
  end

  defp loaded_data(items, now, opts \\ []) do
    %{
      items: items,
      runs: Keyword.get(opts, :runs, %{}),
      views: Keyword.get(opts, :views, %{}),
      titles: Keyword.get(opts, :titles, %{}),
      workspace_names: Keyword.get(opts, :workspace_names, %{"default" => "Handbean"}),
      now: now
    }
  end

  defp tap?(node, tag),
    do: Enum.any?(walk(node), &match?(%{props: %{on_tap: {_, ^tag}}}, &1))

  # `text/1` only concatenates :text nodes; button labels live on
  # :settings_button nodes, so read the label off the tapped node itself.
  defp tap_text(view, tag) do
    view
    |> tree()
    |> walk()
    |> Enum.find_value(fn
      %{props: %{on_tap: {_, ^tag}, text: text}} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp flatten_text(node) do
    node
    |> walk()
    |> Enum.map(& &1.props[:text])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp walk(list) when is_list(list), do: Enum.flat_map(list, &walk/1)
  defp walk(%{children: children} = node), do: [node | walk(children)]
  defp walk(%{} = node), do: [node]
  defp walk(_), do: []
end
