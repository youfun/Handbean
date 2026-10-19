defmodule Handbean.Schedule.StoreBatchTest do
  use Handbean.DataCase, async: false

  alias Handbean.ConversationStore
  alias Handbean.Schedule.{Entry, Run, Store}
  alias Handbean.Storage.Conversation

  @base ~U[2026-05-01 00:00:00Z]

  describe "recent_runs_by_schedule/2" do
    test "groups runs per schedule with the newest run first and honors the limit" do
      first = insert_schedule("first")
      second = insert_schedule("second")

      for minute <- 1..3, do: insert_run(first, minute)
      for minute <- 1..2, do: insert_run(second, minute)

      runs = Store.recent_runs_by_schedule([first, second], 2)

      assert runs |> Map.keys() |> Enum.sort() == [first, second] |> Enum.sort()

      assert run_ids(runs[first]) == [run_id(first, 3), run_id(first, 2)]
      assert run_ids(runs[second]) == [run_id(second, 2), run_id(second, 1)]

      assert run_ids(runs[first]) == first |> Store.recent_runs(2) |> run_ids()

      assert run_ids(Store.recent_runs_by_schedule([first, second], 5)[first]) ==
               [run_id(first, 3), run_id(first, 2), run_id(first, 1)]
    end

    test "returns only runs of the given schedules" do
      wanted = insert_schedule("wanted")
      other = insert_schedule("other")

      insert_run(wanted, 1)
      insert_run(other, 1)

      runs = Store.recent_runs_by_schedule([wanted])

      assert run_ids(runs[wanted]) == [run_id(wanted, 1)]
      refute Map.has_key?(runs, other)
    end

    test "returns an empty map for an empty id list" do
      insert_schedule("unused")

      assert Store.recent_runs_by_schedule([]) == %{}
      assert Store.recent_runs_by_schedule([], 5) == %{}
      assert Store.recent_runs_by_schedule(["", "  "]) == %{}
    end

    test "omits schedules without runs" do
      idle = insert_schedule("idle")
      busy = insert_schedule("busy")

      insert_run(busy, 1)

      assert Store.recent_runs_by_schedule([idle, busy], 2) |> Map.keys() == [busy]
    end
  end

  describe "count/0" do
    test "matches the number of persisted schedules" do
      assert Store.count() == 0

      insert_schedule("one")
      insert_schedule("two")

      assert Store.count() == 2
    end
  end

  describe "titles_for_ids/1" do
    test "returns a title map for the given conversations" do
      {:ok, _} = ConversationStore.create("default", id: "batch-title-a", title: "阿尔法")
      {:ok, _} = ConversationStore.create("default", id: "batch-title-b", title: "Beta 计划")
      {:ok, _} = ConversationStore.create("default", id: "batch-title-c")

      titles =
        ConversationStore.titles_for_ids(["batch-title-a", "batch-title-b", "batch-title-c"])

      assert titles == %{
               "batch-title-a" => "阿尔法",
               "batch-title-b" => "Beta 计划",
               "batch-title-c" => "New chat"
             }
    end

    test "omits unknown and non-active conversation ids" do
      {:ok, _} = ConversationStore.create("default", id: "batch-title-gone", title: "Bye")

      Repo.update_all(from(c in Conversation, where: c.id == "batch-title-gone"),
        set: [status: "pending_delete"]
      )

      assert ConversationStore.titles_for_ids(["batch-title-gone", "batch-title-missing"]) == %{}
      assert ConversationStore.titles_for_ids([]) == %{}
    end
  end

  defp insert_schedule(name) do
    id = "batch-schedule-#{name}"
    conversation_id = "batch-conversation-#{name}"
    {:ok, _} = ConversationStore.create("default", id: conversation_id, title: "对话 #{name}")

    {1, _} =
      Repo.insert_all(Entry, [
        %{
          id: id,
          workspace_id: "default",
          conversation_id: conversation_id,
          name: name,
          instruction: "run #{name}",
          rule: %{"kind" => "interval", "every_minutes" => 30},
          time_zone: "Asia/Shanghai",
          model: "fake/model",
          status: "active",
          version: 1,
          created_by: "user",
          inserted_at: @base,
          updated_at: @base
        }
      ])

    id
  end

  defp insert_run(schedule_id, minute) do
    at = DateTime.add(@base, minute * 60, :second)

    {1, _} =
      Repo.insert_all(Run, [
        %{
          id: run_id(schedule_id, minute),
          schedule_id: schedule_id,
          slot_at: at,
          kind: "scheduled",
          request_id: "req-#{schedule_id}-#{minute}",
          status: "completed",
          inserted_at: at,
          updated_at: at
        }
      ])

    at
  end

  defp run_id(schedule_id, minute), do: "#{schedule_id}-run-#{minute}"
  defp run_ids(runs), do: Enum.map(runs, & &1.id)
end
