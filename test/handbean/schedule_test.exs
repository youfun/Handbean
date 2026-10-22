defmodule Handbean.ScheduleTest do
  use Handbean.DataCase, async: false

  import ExUnit.CaptureLog

  alias Handbean.Agent.{Config, Message, State}
  alias Handbean.Agent.Middleware.ToolGuard
  alias Handbean.ConversationStore
  alias Handbean.Permissions.ToolPolicy
  alias Handbean.Schedule.{Clock, Dispatch, Presentation, Rule, Run, Store}
  alias Handbean.Tool.Builtin.Schedule, as: ScheduleTool

  @zone "Asia/Shanghai"
  @ny "America/New_York"

  defmodule BusyRunner do
    use GenServer

    def start_link(conversation_id, run_id),
      do: GenServer.start_link(__MODULE__, {conversation_id, run_id})

    @impl true
    def init({conversation_id, run_id}) do
      {:ok, _} =
        Registry.register(Handbean.AgentRunRegistry, conversation_id, %{
          run_id: run_id,
          active?: true
        })

      {:ok, %{conversation_id: conversation_id, run_id: run_id}}
    end

    @impl true
    def handle_call(:status, _from, state) do
      {:reply,
       {:ok,
        %{
          conversation_id: state.conversation_id,
          run_id: state.run_id,
          running?: true,
          status: :running,
          run_pid: self()
        }}, state}
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:handbean, :schedule_now) end)
    :ok
  end

  test "spring gap uses the first valid instant and fall overlap uses the earlier one" do
    rule = weekly([7], ["02:30"])
    before_gap = ~U[2026-03-08 06:00:00Z]

    assert {:ok, next} = Rule.next_after(rule, @ny, before_gap)
    assert DateTime.to_iso8601(next) == "2026-03-08T07:00:00Z"

    rule = weekly([7], ["01:30"])
    before_overlap = ~U[2026-11-01 04:00:00Z]
    assert {:ok, earlier} = Rule.next_after(rule, @ny, before_overlap)
    assert DateTime.to_iso8601(earlier) == "2026-11-01T05:30:00Z"
  end

  test "interval next time is strict and one minute is legal" do
    rule = %{"kind" => "interval", "every_minutes" => 1}
    now = ~U[2026-07-18 00:00:00Z]
    assert {:ok, next} = Rule.next_after(rule, @zone, now)
    assert DateTime.diff(next, now) == 60

    assert {:error, :invalid_interval} =
             Rule.validate(%{"kind" => "interval", "every_minutes" => 0})
  end

  test "saving a schedule does not create a run" do
    now = ~U[2026-07-18 01:00:00Z]
    {:ok, entry} = create_schedule(now)

    assert entry.next_run_at == ~U[2026-07-18 01:01:00Z]
    assert Store.recent_runs(entry.id) == []
    assert Clock.tick(now) == :ok
    assert Store.recent_runs(entry.id) == []
  end

  test "concurrent claim keeps one slot" do
    now = ~U[2026-07-18 02:00:00Z]
    {:ok, entry} = create_schedule(DateTime.add(now, -60, :second))

    results =
      1..8
      |> Task.async_stream(fn _ -> Store.claim(entry, now) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    # SQLite runs the transactions one at a time, so the losers usually see the
    # slot already taken. Overlapping transactions still report a conflict.
    assert Enum.count(results, fn
             {:error, reason} -> reason in [:conflict, :already_claimed, :not_due]
             _ -> false
           end) == 7
  end

  test "a missed window claims only the latest slot and records the skip" do
    due = ~U[2026-07-18 03:00:00Z]
    {:ok, entry} = create_schedule(due)
    later = DateTime.add(due, 5 * 60, :second)

    assert {:ok, claim} = Store.claim(entry, later)
    # The first slot is one minute after creation, so 03:05 runs that minute
    # and skips the four minutes before it.
    assert claim.missed == 4
    assert claim.run.kind == "catch_up"
    assert claim.run.slot_at == DateTime.add(due, 5 * 60, :second)
    assert claim.skipped.status == "skipped"
    assert claim.skipped.reason =~ "missed:4"
  end

  test "pause, update, and a failed slot do not fire again" do
    now = ~U[2026-07-18 04:00:00Z]
    {:ok, entry} = create_schedule(now)

    assert {:ok, paused} = Store.pause(entry, now)
    assert Clock.tick(DateTime.add(now, 120, :second)) == :ok
    assert Store.recent_runs(paused.id) == []

    assert {:ok, resumed} = Store.resume(paused, now)
    assert resumed.next_run_at == DateTime.add(now, 60, :second)
    assert {:ok, updated} = Store.update(resumed, %{name: "renamed"}, now)
    assert updated.next_run_at == resumed.next_run_at
    assert Store.recent_runs(updated.id) == []

    assert {:ok, claim} = Store.claim(updated, updated.next_run_at)
    assert {:ok, failed} = Store.record(claim.run, "failed", reason: "provider")
    assert Clock.tick(updated.next_run_at) == :ok
    assert Enum.count(Store.recent_runs(updated.id), &(&1.slot_at == failed.slot_at)) == 1
  end

  test "a claimed run that never finishes becomes unknown and is not retried" do
    now = ~U[2026-07-18 05:00:00Z]
    {:ok, entry} = create_schedule(now)
    assert {:ok, _claim} = Store.claim(entry, entry.next_run_at)

    assert [%Run{status: "unknown"}] =
             Store.recover_unknown(DateTime.add(now, 120, :second), fn _, _ -> false end)

    assert Clock.tick(DateTime.add(now, 180, :second)) == :ok
    assert Enum.count(Store.recent_runs(entry.id), &(&1.status == "unknown")) == 1
    refute Enum.any?(Store.recent_runs(entry.id), &(&1.status == "claimed"))
  end

  test "an archived conversation disables the schedule" do
    now = ~U[2026-07-18 06:00:00Z]
    {:ok, entry} = create_schedule(now)
    {:ok, _} = ConversationStore.archive(entry.conversation_id)

    assert Clock.tick(entry.next_run_at) == :ok
    assert {:ok, disabled} = Store.get(entry.id)
    assert disabled.status == "disabled"

    assert [%Run{status: "skipped", reason: "conversation_unavailable"}] =
             Store.recent_runs(entry.id)
  end

  test "a scheduled source cannot change a schedule and another conversation is hidden" do
    now = ~U[2026-07-18 07:00:00Z]
    {:ok, entry} = create_schedule(now)

    context = %{
      conversation_id: entry.conversation_id,
      workspace_id: entry.workspace_id,
      source: :schedule
    }

    assert {:error, "schedule_changes_require_user_turn"} =
             ScheduleTool.execute(%{"action" => "pause", "id" => entry.id}, context)

    other = %{context | conversation_id: "other-conversation", source: :live_view}

    assert {:error, "not_found"} =
             ScheduleTool.execute(%{"action" => "get", "id" => entry.id}, other)
  end

  test "schedule writes prompt unless they are status-only, one-shot, or yolo" do
    policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
    yolo = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "yolo"}})
    once = %{"kind" => "once", "in_minutes" => 5}

    assert ToolPolicy.decision(policy, call("create", %{"rule" => %{}})) == :prompt
    assert ToolPolicy.decision(policy, call("create", %{"rule" => once})) == :auto
    assert ToolPolicy.decision(policy, call("update", %{"rule" => once})) == :auto
    assert ToolPolicy.decision(policy, call("run_now", %{})) == :prompt
    assert ToolPolicy.decision(policy, call("update", %{"rule" => %{}})) == :prompt
    assert ToolPolicy.decision(policy, call("pause", %{})) == :auto
    assert ToolPolicy.decision(yolo, call("create", %{"rule" => %{}})) == :auto
  end

  test "a scheduled run halts instead of waiting for approval" do
    workspace =
      Path.join(System.tmp_dir!(), "handbean_schedule_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".handbean"))
    on_exit(fn -> File.rm_rf!(workspace) end)

    File.write!(
      Path.join(workspace, ".handbean/settings.jsonc"),
      Handbean.JSON.encode!(%{
        "tools" => %{"default_mode" => "auto", "per_tool" => %{"read" => "prompt"}}
      })
    )

    assert %ToolPolicy{per_tool: %{"read" => :prompt}} = ToolPolicy.from_workspace(workspace)

    config = %Config{
      working_directory: workspace,
      model: "fake",
      middleware: [],
      source: :schedule
    }

    state =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([
          %{type: "tool_use", id: "c1", name: "read", input: %{"file_path" => "fixture.txt"}}
        ])
      ])

    assert {:tool_guard_denied, halted} = ToolGuard.call(:after_tool_request, state)
    assert halted.status == :halted
    assert halted.error =~ "read"
  end

  # Invariant: a terminal run_end may arrive while the SQL sandbox owner is
  # dying. Recording that finish must not stop Schedule.Recorder. Three deaths
  # inside the supervisor window take the whole application down, and the rest
  # of the suite then fails because Repo, PubSub, and the journal are gone.
  test "a sandbox owner exiting during finish leaves the recorder running" do
    recorder = Process.whereis(Handbean.Schedule.Recorder)
    assert is_pid(recorder)
    ref = Process.monitor(recorder)

    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    parent = self()

    owner =
      spawn(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
        :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

        Repo.transaction(fn ->
          send(parent, :holding)

          receive do
            :release -> :ok
          end
        end)
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: send(owner, :release)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    assert_receive :holding, 1_000
    await_recorder_checkout(recorder)

    log =
      capture_log(fn ->
        Process.exit(owner, :kill)
        refute_receive {:DOWN, ^ref, :process, ^recorder, _reason}, 200
      end)

    assert Process.whereis(Handbean.Schedule.Recorder) == recorder
    assert log =~ "Schedule.Recorder"
  end

  test "three Asia/Shanghai days claim each daily and interval slot once" do
    start = ~U[2026-07-20 00:00:00Z]

    {:ok, daily} =
      create_schedule(start,
        rule: weekly([1, 2, 3, 4, 5, 6, 7], ["09:00"]),
        conversation_id: unique_id("daily")
      )

    {:ok, interval} =
      create_schedule(start,
        rule: %{"kind" => "interval", "every_minutes" => 12 * 60},
        conversation_id: unique_id("interval")
      )

    Enum.each(0..(3 * 24), fn hour ->
      assert :ok = Clock.tick(DateTime.add(start, hour * 3600, :second))
    end)

    daily_slots = Store.recent_runs(daily.id) |> Enum.map(& &1.slot_at) |> Enum.reject(&is_nil/1)

    interval_slots =
      Store.recent_runs(interval.id) |> Enum.map(& &1.slot_at) |> Enum.reject(&is_nil/1)

    assert length(daily_slots) == 3
    assert daily_slots == Enum.uniq(daily_slots)
    assert length(interval_slots) == 6
    assert interval_slots == Enum.uniq(interval_slots)
  end

  test "five minutes freezes to one absolute instant and does not repeat" do
    now = ~U[2026-08-01 00:00:00Z]
    Application.put_env(:handbean, :schedule_now, fn -> now end)
    id = conversation!()

    assert {:ok, encoded} =
             ScheduleTool.execute(
               once_input(%{"kind" => "once", "in_minutes" => 5}),
               tool_context(id)
             )

    {:ok, %{"id" => schedule_id}} = Handbean.JSON.decode(encoded)
    {:ok, entry} = Store.get(schedule_id)
    at = DateTime.add(now, 5 * 60, :second)

    assert entry.rule["kind"] == "once"
    assert entry.rule["at"] == DateTime.to_iso8601(at)
    assert entry.rule["label"] == "5 分钟后，只一次"
    assert entry.next_run_at == at
    assert Store.recent_runs(entry.id) == []

    assert Clock.tick(now) == :ok
    assert Store.recent_runs(entry.id) == []

    assert Clock.tick(at) == :ok
    assert [run] = Store.recent_runs(entry.id)
    assert run.slot_at == at
    {:ok, done} = Store.get(entry.id)
    assert done.status == "completed"
    assert is_nil(done.next_run_at)

    assert Clock.tick(DateTime.add(at, 3_600, :second)) == :ok
    assert Store.recent_runs(entry.id) == [run]
  end

  test "a one-shot without a time is rejected and nothing is stored" do
    now = ~U[2026-08-01 00:10:00Z]
    Application.put_env(:handbean, :schedule_now, fn -> now end)
    id = conversation!()

    assert {:error, "invalid_rule"} =
             ScheduleTool.execute(once_input(%{"kind" => "once"}), tool_context(id))

    assert {:error, "invalid_once"} =
             ScheduleTool.execute(
               once_input(%{"kind" => "once", "in_minutes" => 0}),
               tool_context(id)
             )

    assert {:error, :invalid_rule} =
             Rule.prepare_once(
               %{"kind" => "once", "in_minutes" => 5, "at" => "2026-08-01T09:00"},
               @zone,
               now
             )

    assert Store.list_for_conversation(id) == []
  end

  test "a canonical one-shot less than one minute away is rejected" do
    now = ~U[2026-08-01 00:15:00Z]

    assert {:error, :too_soon} =
             Rule.prepare_once(
               %{
                 "kind" => "once",
                 "at" => DateTime.to_iso8601(DateTime.add(now, 30, :second)),
                 "label" => "30 秒后，只一次"
               },
               @zone,
               now
             )

    assert {:ok, %{at: at}} =
             Rule.prepare_once(
               %{
                 "kind" => "once",
                 "at" => DateTime.to_iso8601(DateTime.add(now, 60, :second)),
                 "label" => "1 分钟后，只一次"
               },
               @zone,
               now
             )

    assert at == DateTime.add(now, 60, :second)
  end

  test "saving freezes the instant and a late save creates nothing" do
    now = ~U[2026-08-01 00:20:00Z]
    Application.put_env(:handbean, :schedule_now, fn -> now end)

    config = %Config{
      working_directory: System.tmp_dir!(),
      model: "fake",
      middleware: [],
      context: %{user_time_zone: @zone}
    }

    state =
      config
      |> State.init("5 minutes")
      |> State.append_messages([
        Message.tool_use([
          %{
            type: "tool_use",
            id: "once-1",
            name: "schedule",
            input: once_input(%{"kind" => "once", "in_minutes" => 5})
          }
        ])
      ])

    frozen = guard_state(ToolGuard.call(:after_tool_request, state))
    at = DateTime.add(now, 5 * 60, :second)
    assert tool_rule(frozen)["at"] == DateTime.to_iso8601(at)
    assert tool_rule(frozen)["label"] == "5 分钟后，只一次"

    later = DateTime.add(now, 4 * 60, :second)
    Application.put_env(:handbean, :schedule_now, fn -> later end)
    refrozen = ScheduleTool.freeze_messages(frozen.messages, %{user_time_zone: @zone}, later)
    assert tool_rule(%{messages: refrozen})["at"] == DateTime.to_iso8601(at)

    id = conversation!()
    Application.put_env(:handbean, :schedule_now, fn -> DateTime.add(at, 1, :second) end)

    assert {:error, ":in_the_past"} =
             ScheduleTool.execute(
               once_input(%{
                 "kind" => "once",
                 "at" => DateTime.to_iso8601(at),
                 "label" => "5 分钟后，只一次"
               }),
               tool_context(id)
             )

    assert Store.list_for_conversation(id) == []
  end

  test "a busy conversation waits, then skips once after thirty minutes" do
    now = ~U[2026-08-01 01:00:00Z]
    at = DateTime.add(now, 60, :second)
    {:ok, entry} = create_once(now, at: at)
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:schedules")
    busy_runner = mark_busy(entry.conversation_id)
    on_exit(fn -> clear_busy(entry.conversation_id, busy_runner) end)

    Enum.each(0..9, fn minute ->
      assert Clock.tick(DateTime.add(at, minute * 60, :second)) == :ok
    end)

    assert Store.recent_runs(entry.id) == []
    {:ok, waiting} = Store.get(entry.id)
    assert waiting.status == "active"
    assert waiting.next_run_at == at
    refute_received {:schedule_notice, _, _}

    deadline = DateTime.add(at, 30 * 60, :second)
    assert Clock.tick(deadline) == :ok
    assert [%Run{status: "skipped", reason: "busy", slot_at: ^at}] = Store.recent_runs(entry.id)
    {:ok, done} = Store.get(entry.id)
    assert done.status == "completed"
    assert is_nil(done.next_run_at)
    assert_receive {:schedule_notice, conv, notice} when conv == entry.conversation_id
    assert notice["content"] =~ "已跳过"

    assert Clock.tick(DateTime.add(deadline, 60, :second)) == :ok
    assert length(Store.recent_runs(entry.id)) == 1
  end

  test "a busy one-shot backs off the clock without moving its persisted time" do
    now = ~U[2026-08-01 01:30:00Z]
    at = DateTime.add(now, 60, :second)
    {:ok, entry} = create_once(now, at: at)
    busy_runner = mark_busy(entry.conversation_id)
    on_exit(fn -> clear_busy(entry.conversation_id, busy_runner) end)
    Application.put_env(:handbean, :schedule_now, fn -> at end)

    previous_clock = Application.get_env(:handbean, :schedule_clock)
    Application.put_env(:handbean, :schedule_clock, enabled: true)

    on_exit(fn ->
      if previous_clock,
        do: Application.put_env(:handbean, :schedule_clock, previous_clock),
        else: Application.delete_env(:handbean, :schedule_clock)

      Clock.tick(at)
    end)

    assert Clock.tick(at) == :ok

    state = :sys.get_state(Clock)
    assert is_reference(state.timer)
    assert Process.read_timer(state.timer) > 0
    entry_id = entry.id
    assert %{^entry_id => retry_not_before} = state.busy_retries
    assert retry_not_before > System.monotonic_time(:millisecond)
    assert {:ok, waiting} = Store.get(entry.id)
    assert waiting.next_run_at == at
    assert waiting.status == "active"
  end

  test "a sub-millisecond busy deadline still records a positive retry" do
    now = ~U[2026-08-01 01:40:00Z]
    at = DateTime.add(now, 60, :second)
    {:ok, entry} = create_once(now, at: at)
    busy_runner = mark_busy(entry.conversation_id)
    on_exit(fn -> clear_busy(entry.conversation_id, busy_runner) end)

    deadline = DateTime.add(at, 30 * 60, :second)
    boundary = DateTime.add(deadline, -500, :microsecond)
    Application.put_env(:handbean, :schedule_now, fn -> boundary end)
    monotonic_before = System.monotonic_time(:millisecond)

    assert Clock.tick(boundary) == :ok
    entry_id = entry.id
    assert %{^entry_id => retry_not_before} = :sys.get_state(Clock).busy_retries
    assert retry_not_before >= monotonic_before + 1
    assert Store.recent_runs(entry.id) == []
  end

  test "a busy one-shot retry does not hide an independent schedule due in 100ms" do
    now = ~U[2026-08-01 01:50:00Z]
    busy_at = DateTime.add(now, 60, :second)
    idle_at = DateTime.add(busy_at, 1, :second)
    {:ok, busy} = create_once(now, at: busy_at)
    {:ok, idle} = create_once(now, at: idle_at)
    busy_runner = mark_busy(busy.conversation_id)
    on_exit(fn -> clear_busy(busy.conversation_id, busy_runner) end)

    clock_now = DateTime.add(busy_at, 900, :millisecond)
    Application.put_env(:handbean, :schedule_now, fn -> clock_now end)
    previous_clock = Application.get_env(:handbean, :schedule_clock)
    Application.put_env(:handbean, :schedule_clock, enabled: true)

    on_exit(fn ->
      if previous_clock,
        do: Application.put_env(:handbean, :schedule_clock, previous_clock),
        else: Application.delete_env(:handbean, :schedule_clock)

      Clock.tick(clock_now)
    end)

    assert Clock.tick(clock_now) == :ok
    state = :sys.get_state(Clock)
    busy_id = busy.id
    assert %{^busy_id => _retry_not_before} = state.busy_retries
    assert is_reference(state.timer)
    assert remaining = Process.read_timer(state.timer)
    assert remaining in 1..100
    assert Store.recent_runs(idle.id) == []
  end

  test "an idle one-shot catches up one slot however late it is" do
    now = ~U[2026-08-01 02:00:00Z]
    at = DateTime.add(now, 60, :second)
    {:ok, entry} = create_once(now, at: at)
    late = DateTime.add(at, 5 * 3_600, :second)

    assert Clock.tick(late) == :ok
    assert [run] = Store.recent_runs(entry.id)
    assert run.slot_at == at
    {:ok, done} = Store.get(entry.id)
    assert done.status == "completed"
    assert is_nil(done.next_run_at)

    assert Clock.tick(DateTime.add(late, 60, :second)) == :ok
    assert Store.recent_runs(entry.id) == [run]
  end

  test "releasing an unstarted claim lets the same slot start, and a started claim stays put" do
    now = ~U[2026-08-01 03:00:00Z]
    at = DateTime.add(now, 60, :second)
    {:ok, entry} = create_once(now, at: at)
    assert {:ok, claim} = Store.claim(entry, at)
    request_id = claim.run.request_id

    assert {:ok, released} = Store.release_claim(claim.run)
    assert released.status == "active"
    assert released.next_run_at == at
    assert Store.recent_runs(entry.id) == []

    assert {:ok, again} = Store.claim(released, at)
    assert again.run.request_id == request_id
    assert {:ok, started} = Store.record(again.run, "started", run_id: "run-started")
    assert {:error, :not_releasable} = Store.release_claim(started)
    assert [%Run{status: "started"}] = Store.recent_runs(entry.id)
  end

  test "manual one-shot runs never consume or restore the planned slot" do
    now = ~U[2026-08-01 03:30:00Z]
    at = DateTime.add(now, 300, :second)
    {:ok, entry} = create_once(now, at: at)

    assert {:ok, first} = Store.run_now(entry, now)
    assert {:ok, %{run: completed}} = Store.finish_run(first.run, "completed", now: now)
    assert completed.status == "completed"

    {:ok, still_planned} = Store.get(entry.id)
    assert still_planned.status == "active"
    assert still_planned.next_run_at == at

    assert {:ok, second} = Store.run_now(still_planned, now)
    assert {:ok, started} = Store.record(second.run, "started", run_id: "manual-run")
    assert :ok = Store.finish_by_run_id(started.run_id, "failed", "provider")

    {:ok, after_failure} = Store.get(entry.id)
    assert after_failure.status == "active"
    assert after_failure.next_run_at == at

    assert {:ok, third} = Store.run_now(after_failure, now)
    assert {:error, :not_releasable} = Store.release_claim(third.run)

    {:ok, after_release} = Store.get(entry.id)
    assert after_release.status == "active"
    assert after_release.next_run_at == at
    assert Enum.any?(Store.recent_runs(entry.id), &(&1.id == third.run.id))

    armed = Presentation.once(after_release, Store.recent_runs(entry.id), now)
    assert armed.headline == "5 分钟后，只一次"

    waiting = Presentation.once(after_release, Store.recent_runs(entry.id), at)
    assert "对话正忙，空闲后开始" in waiting.lines
  end

  test "recovering an unknown manual one-shot leaves its parent scheduled" do
    now = ~U[2026-08-01 03:45:00Z]
    at = DateTime.add(now, 300, :second)
    {:ok, entry} = create_once(now, at: at)
    assert {:ok, manual} = Store.run_now(entry, now)

    assert [%Run{id: id, status: "unknown"}] =
             Store.recover_unknown(DateTime.add(now, 60, :second), fn _, _ -> false end)

    assert id == manual.run.id
    {:ok, still_planned} = Store.get(entry.id)
    assert still_planned.status == "active"
    assert still_planned.next_run_at == at
  end

  test "pausing across the instant does not catch up, and resume only works while it is still ahead" do
    now = ~U[2026-08-01 04:00:00Z]
    at = DateTime.add(now, 120, :second)
    {:ok, entry} = create_once(now, at: at)
    assert {:ok, paused} = Store.pause(entry, now)
    assert Clock.tick(DateTime.add(at, 600, :second)) == :ok
    assert Store.recent_runs(entry.id) == []

    assert {:error, :in_the_past} = Store.resume(paused, DateTime.add(at, 600, :second))
    {:ok, still} = Store.get(entry.id)
    assert still.status == "paused"
    assert is_nil(still.next_run_at)

    {:ok, early} = create_once(now, at: at)
    {:ok, early_paused} = Store.pause(early, now)
    assert {:ok, resumed} = Store.resume(early_paused, DateTime.add(now, 30, :second))
    assert resumed.status == "active"
    assert resumed.next_run_at == at
  end

  test "a one-shot terminal write is atomic and a completed one cannot be paused back to life" do
    now = ~U[2026-08-01 05:00:00Z]
    at = DateTime.add(now, 60, :second)
    {:ok, entry} = create_once(now, at: at)
    assert {:ok, claim} = Store.claim(entry, at)
    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:schedules")

    on_exit(fn -> Application.delete_env(:handbean, :schedule_finish_fault) end)

    Application.put_env(:handbean, :schedule_finish_fault, fn :after_run ->
      {:error, :injected}
    end)

    assert {:error, :injected} = Store.finish_run(claim.run, "completed")
    refute_received {:schedule_changed, _}
    {:ok, pending} = Store.get(entry.id)
    assert pending.status == "active"
    assert is_nil(pending.next_run_at)
    assert [%Run{status: "claimed"}] = Store.recent_runs(entry.id)

    Application.delete_env(:handbean, :schedule_finish_fault)
    assert {:ok, %{schedule: done}} = Store.finish_run(claim.run, "completed")
    assert done.status == "completed"
    assert is_nil(done.next_run_at)
    assert_receive {:schedule_changed, conv} when conv == entry.conversation_id
    assert [%Run{status: "completed"}] = Store.recent_runs(entry.id)
    assert {:error, :not_pausable} = Store.pause(done, now)
    {:ok, still} = Store.get(entry.id)
    assert still.status == "completed"
  end

  test "an unfinished one-shot claim becomes unknown and is not retried" do
    now = ~U[2026-08-01 06:00:00Z]
    at = DateTime.add(now, 60, :second)
    {:ok, entry} = create_once(now, at: at)
    assert {:ok, _claim} = Store.claim(entry, at)

    assert [%Run{status: "unknown"}] =
             Store.recover_unknown(DateTime.add(at, 120, :second), fn _, _ -> false end)

    {:ok, done} = Store.get(entry.id)
    assert done.status == "completed"
    assert is_nil(done.next_run_at)
    assert Clock.tick(DateTime.add(at, 600, :second)) == :ok
    assert [run] = Store.recent_runs(entry.id)
    assert run.status == "unknown"

    view = Presentation.once(done, [run], at)
    assert view.headline == "结果不明，不会自动重跑"
    assert view.headline != "已完成"
  end

  test "the card and the sidebar use the run result, not a second success story" do
    now = ~U[2026-08-01 07:00:00Z]
    at = DateTime.add(now, 300, :second)
    {:ok, armed} = create_once(now, at: at)
    armed_view = Presentation.once(armed, [], now)
    assert armed_view.switch == :on
    assert armed_view.action == :pause
    assert "下次还要" in armed_view.lines
    assert armed_view.headline == "5 分钟后，只一次"

    {:ok, claim} = Store.claim(armed, at)
    assert {:ok, %{schedule: failed_parent, run: failed}} = Store.finish_run(claim.run, "failed")
    failed_view = Presentation.once(failed_parent, [failed], at)
    assert failed_view.headline == "失败"
    assert failed_view.headline != "已完成"
    assert "没有下次" in failed_view.lines

    {:ok, other} = create_once(now, at: at)
    {:ok, other_claim} = Store.claim(other, at)
    {:ok, %{schedule: done, run: completed}} = Store.finish_run(other_claim.run, "completed")
    done_view = Presentation.once(done, [completed], at)
    assert done_view.headline == "已完成"
    assert done_view.switch == :off
    assert "没有下次" in done_view.lines

    assert Presentation.deleted().headline == "已删除"
    assert Presentation.deleted().lines == ["已删除"]
  end

  test "a repeating schedule stays active when a slot does not run" do
    now = ~U[2026-08-01 08:00:00Z]
    {:ok, entry} = create_schedule(DateTime.add(now, -60, :second))
    assert Clock.tick(now) == :ok
    {:ok, current} = Store.get(entry.id)
    assert current.status == "active"
    assert current.next_run_at
    assert [%Run{status: "skipped"}] = Store.recent_runs(entry.id)
  end

  defp create_schedule(now, extra \\ []) do
    id = Keyword.get(extra, :conversation_id, unique_id("sched"))
    {:ok, _} = ConversationStore.create("default", id: id, title: "Schedule")
    Application.put_env(:handbean, :schedule_now, fn -> now end)

    Store.create(%{
      workspace_id: "default",
      conversation_id: id,
      name: "digest",
      instruction: "summarize",
      rule: Keyword.get(extra, :rule, %{"kind" => "interval", "every_minutes" => 1}),
      time_zone: @zone,
      model: "fake/model",
      created_by: "user"
    })
  end

  defp create_once(now, extra) do
    at = Keyword.fetch!(extra, :at)

    create_schedule(now,
      rule: %{
        "kind" => "once",
        "at" => DateTime.to_iso8601(at),
        "label" => "5 分钟后，只一次"
      }
    )
  end

  defp conversation! do
    id = unique_id("once")
    {:ok, _} = ConversationStore.create("default", id: id, title: "Once")
    id
  end

  defp once_input(rule) do
    %{
      "action" => "create",
      "name" => "Check",
      "instruction" => "看编译",
      "model" => "fake/model",
      "time_zone" => @zone,
      "rule" => rule
    }
  end

  defp tool_context(conversation_id) do
    %{
      conversation_id: conversation_id,
      workspace_id: "default",
      source: :live_view,
      user_time_zone: @zone
    }
  end

  defp guard_state(%State{} = state), do: state
  defp guard_state({_, %State{} = state}), do: state
  defp guard_state({_, %State{} = state, _data}), do: state
  defp guard_state({_, _, %State{} = state}), do: state

  defp tool_rule(%{messages: messages}) do
    messages
    |> Enum.find(&(&1.role == :assistant))
    |> Map.fetch!(:content)
    |> Enum.find(&(Map.get(&1, :type) == "tool_use" or Map.get(&1, "type") == "tool_use"))
    |> then(fn block ->
      input = Map.get(block, :input) || Map.get(block, "input")
      input["rule"] || input[:rule]
    end)
  end

  test "a stale TaskTracker projection cannot block scheduler admission" do
    conversation_id = conversation!()

    send(
      Process.whereis(Handbean.Runtime.TaskTracker),
      {:run_lifecycle, conversation_id, :run_start, %{run_id: "stale-projection"}}
    )

    assert Enum.any?(
             Handbean.Runtime.TaskTracker.snapshot().tasks,
             &(&1.conversation_id == conversation_id)
           )

    refute Dispatch.busy?(conversation_id)

    send(
      Process.whereis(Handbean.Runtime.TaskTracker),
      {:run_lifecycle, conversation_id, :run_end,
       %{status: "completed", run_id: "stale-projection"}}
    )

    Handbean.Runtime.TaskTracker.snapshot()
  end

  defp mark_busy(conversation_id) do
    {:ok, pid} = BusyRunner.start_link(conversation_id, "busy-#{conversation_id}")
    assert Dispatch.busy?(conversation_id)
    pid
  end

  defp clear_busy(conversation_id, runner) do
    if is_pid(runner) and Process.alive?(runner), do: GenServer.stop(runner)

    send(
      Process.whereis(Handbean.Runtime.TaskTracker),
      {:run_lifecycle, conversation_id, :run_end,
       %{status: "completed", run_id: "busy-#{conversation_id}"}}
    )

    Handbean.Runtime.TaskTracker.snapshot()
  end

  defp weekly(days, times), do: %{"kind" => "weekly", "weekdays" => days, "times" => times}

  defp call(action, input) do
    %{id: "call", name: "schedule", input: Map.put(input, "action", action)}
  end

  defp unique_id(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp await_recorder_checkout(recorder) do
    Phoenix.PubSub.broadcast(
      Handbean.PubSub,
      "runtime:runs",
      {:run_lifecycle, "recorder-owner-exit", :run_end,
       %{status: "cancelled", run_id: Ecto.UUID.generate(), turns: 0}}
    )

    deadline = System.monotonic_time(:millisecond) + 1_000
    await_recorder_checkout(recorder, deadline)
  end

  defp await_recorder_checkout(recorder, deadline) do
    case Process.info(recorder, :current_stacktrace) do
      {:current_stacktrace, stack} ->
        if Enum.any?(stack, &checkout_frame?/1) do
          :ok
        else
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("recorder did not block in checkout:\n#{Exception.format_stacktrace(stack)}")
          else
            receive do
            after
              5 -> await_recorder_checkout(recorder, deadline)
            end
          end
        end

      nil ->
        flunk("recorder exited before checkout")
    end
  end

  defp checkout_frame?({DBConnection.Holder, :checkout, _, _}), do: true
  defp checkout_frame?({:gen, :do_call, _, _}), do: true
  defp checkout_frame?(_frame), do: false
end
