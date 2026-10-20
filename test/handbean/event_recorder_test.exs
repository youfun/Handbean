defmodule Handbean.EventRecorderTest do
  use ExUnit.Case, async: true

  alias Handbean.EventRecorder
  alias Handbean.PubSub.AgentEvent

  test "default event directory follows the configured Handbean home" do
    sid = "event-recorder-default-#{System.unique_integer([:positive])}"
    event = AgentEvent.new("session:#{sid}", :run_start, %{model: "fake"}, 1)
    path = EventRecorder.event_path(sid)

    on_exit(fn -> File.rm(path) end)

    assert path == Path.join(Handbean.Home.expand("~/.handbean/events"), "#{sid}.jsonl")
    assert :ok = EventRecorder.record(sid, event)
    assert File.exists?(path)
  end

  test "records important events to jsonl with redaction" do
    dir =
      "~/.handbean/events"
      |> Handbean.Home.expand()
      |> Path.join("test_#{System.unique_integer([:positive])}")

    sid = "event-recorder"

    event =
      AgentEvent.new("session:#{sid}", :run_start, %{api_key: "sk-secret", model: "fake"}, 1)

    assert :ok = EventRecorder.record(sid, event, event_dir: dir)

    path = EventRecorder.event_path(sid, event_dir: dir)
    assert File.exists?(path)
    body = File.read!(path)
    assert body =~ "run_start"
    refute body =~ "sk-secret"
    assert body =~ "[REDACTED]"
  end

  test "skips high-frequency message_delta events" do
    dir =
      "~/.handbean/events"
      |> Handbean.Home.expand()
      |> Path.join("test_skip_#{System.unique_integer([:positive])}")

    sid = "event-recorder-skip"

    event = AgentEvent.new("session:#{sid}", :message_delta, %{chunk: "hello"}, 1)

    assert :ok = EventRecorder.record(sid, event, event_dir: dir)
    refute File.exists?(EventRecorder.event_path(sid, event_dir: dir))
  end

  test "event_dir under ~/.handbean/events is accepted" do
    dir =
      "~/.handbean/events"
      |> Handbean.Home.expand()
      |> Path.join("subdir_#{System.unique_integer([:positive])}")

    event = AgentEvent.new("session:ev", :run_start, %{model: "fake"}, 1)
    assert :ok = EventRecorder.record("ev", event, event_dir: dir)
  end
end
