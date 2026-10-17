defmodule Handbean.Log.StoreTest do
  @moduledoc """
  Tests for Handbean.Log.Store — in-process event store.

  The store is an Agent-based append-only list with filter/clear.
  It is NOT supervised by the application — tests start/stop it manually.
  """
  use ExUnit.Case, async: false

  alias Handbean.Log.{Event, Store}

  setup do
    # Ensure clean store for each test
    {:ok, pid} = Store.start_link(name: :test_log_store)
    on_exit(fn -> stop_store(pid) end)
    {:ok, store: pid}
  end

  defp stop_store(pid) do
    try do
      if Process.alive?(pid), do: Store.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  describe "append/2" do
    test "adds event to store", %{store: store} do
      {:ok, event} = Event.new(kind: :session, level: :info, message: "start")
      :ok = Store.append(store, event)

      events = Store.list(store)
      assert length(events) == 1
      assert hd(events).id == event.id
    end

    test "maintains insertion order", %{store: store} do
      {:ok, e1} = Event.new(kind: :general, level: :debug, message: "first")
      {:ok, e2} = Event.new(kind: :general, level: :debug, message: "second")
      {:ok, e3} = Event.new(kind: :general, level: :debug, message: "third")

      Store.append(store, e1)
      Store.append(store, e2)
      Store.append(store, e3)

      events = Store.list(store)
      assert length(events) == 3
      assert Enum.at(events, 0).message == "first"
      assert Enum.at(events, 1).message == "second"
      assert Enum.at(events, 2).message == "third"
    end
  end

  describe "list/1" do
    test "returns empty list for empty store", %{store: store} do
      assert Store.list(store) == []
    end
  end

  describe "filter/2" do
    setup %{store: store} do
      {:ok, e1} =
        Event.new(
          kind: :session,
          level: :info,
          message: "session start",
          session_id: "s1",
          turn: 0
        )

      {:ok, e2} =
        Event.new(
          kind: :tool,
          level: :debug,
          message: "read file",
          session_id: "s1",
          turn: 1,
          source: "read_tool"
        )

      {:ok, e3} =
        Event.new(
          kind: :provider,
          level: :error,
          message: "timeout",
          session_id: "s1",
          turn: 1
        )

      {:ok, e4} =
        Event.new(
          kind: :provider,
          level: :info,
          message: "retry",
          session_id: "s1",
          turn: 1
        )

      {:ok, e5} =
        Event.new(
          kind: :session,
          level: :info,
          message: "session end",
          session_id: "s2",
          turn: 10
        )

      Store.append(store, e1)
      Store.append(store, e2)
      Store.append(store, e3)
      Store.append(store, e4)
      Store.append(store, e5)

      {:ok, store: store}
    end

    test "filters by kind", %{store: store} do
      tool_events = Store.filter(store, kind: :tool)
      assert length(tool_events) == 1
      assert hd(tool_events).kind == :tool
    end

    test "filters by level", %{store: store} do
      error_events = Store.filter(store, level: :error)
      assert length(error_events) == 1
      assert hd(error_events).level == :error
    end

    test "filters by session_id", %{store: store} do
      s1_events = Store.filter(store, session_id: "s1")
      assert length(s1_events) == 4

      s2_events = Store.filter(store, session_id: "s2")
      assert length(s2_events) == 1
    end

    test "filters by multiple criteria", %{store: store} do
      results = Store.filter(store, kind: :provider, level: :info)
      assert length(results) == 1
      assert hd(results).message == "retry"
    end

    test "returns empty list when no matches", %{store: store} do
      results = Store.filter(store, kind: :security)
      assert results == []
    end

    test "returns empty list for unknown filter key", %{store: store} do
      results = Store.filter(store, unknown_field: :value)
      assert results == []
    end
  end

  describe "clear/1" do
    test "removes all events", %{store: store} do
      {:ok, e1} = Event.new(kind: :general, level: :debug, message: "e1")
      {:ok, e2} = Event.new(kind: :general, level: :debug, message: "e2")

      Store.append(store, e1)
      Store.append(store, e2)
      assert length(Store.list(store)) == 2

      Store.clear(store)
      assert Store.list(store) == []
    end
  end

  describe "count/1" do
    test "returns event count", %{store: store} do
      assert Store.count(store) == 0

      {:ok, e1} = Event.new(kind: :general, level: :debug, message: "e1")
      Store.append(store, e1)
      assert Store.count(store) == 1

      {:ok, e2} = Event.new(kind: :general, level: :debug, message: "e2")
      Store.append(store, e2)
      assert Store.count(store) == 2
    end
  end

  describe "store resilience" do
    test "ignores a non-event struct and keeps the store empty" do
      {:ok, store} = Store.start_link(name: :resilient_store)
      on_exit(fn -> stop_store(store) end)

      assert :ok = Store.append(store, %{bad: "data"})
      assert Store.list(store) == []
      assert Process.alive?(store)
    end

    test "survives clear on empty store", %{store: store} do
      Store.clear(store)
      assert Store.list(store) == []
    end
  end
end
