defmodule Handbean.Agent.Turn.StreamTrackerTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Message
  alias Handbean.Agent.Turn.StreamTracker

  test "tracks structured chunks and emits only the unstreamed tail" do
    tracker = StreamTracker.start(true)
    callback = StreamTracker.callback(tracker, true, [], &send(self(), {:delta, &1}))

    callback.(%{text: "hel", phase: "final_answer", output_index: 0})
    callback.(%{text: "lo", phase: "final_answer", output_index: 0})

    assert StreamTracker.emitted?(tracker)
    assert_receive {:delta, %{chunk: "hel", phase: "final_answer", output_index: 0}}
    assert_receive {:delta, %{chunk: "lo", phase: "final_answer", output_index: 0}}

    snapshot = StreamTracker.snapshot(tracker)

    assert snapshot == %{
             text: "hello",
             phases: %{0 => %{phase: "final_answer", text: "hello"}}
           }

    assert :ok =
             StreamTracker.emit_completion(
               true,
               tracker,
               snapshot,
               [Message.assistant([%{type: "text", text: "hello!", phase: "final_answer"}])],
               &send(self(), {:tail, &1}),
               &send(self(), {:messages, &1})
             )

    assert_receive {:tail, %{chunk: "!", phase: "final_answer", output_index: 0}}
    refute_receive {:messages, _}

    assert :ok = StreamTracker.stop(tracker)
  end

  test "reasoning blocks preserve the streamed text output index" do
    tracker = StreamTracker.start(true)
    callback = StreamTracker.callback(tracker, true, [], &send(self(), {:delta, &1}))

    callback.(%{text: "hello", phase: "final_answer", output_index: 1})

    assert_receive {:delta, %{chunk: "hello", phase: "final_answer", output_index: 1}}

    snapshot = StreamTracker.snapshot(tracker)

    messages = [
      Message.assistant_blocks([
        %{type: "responses_reasoning", item: %{type: "reasoning"}},
        %{type: "text", text: "hello", phase: "final_answer", output_index: 1},
        %{type: "text", text: "!", phase: "final_answer", output_index: 1}
      ])
    ]

    assert :ok =
             StreamTracker.emit_completion(
               true,
               tracker,
               snapshot,
               messages,
               &send(self(), {:tail, &1}),
               &send(self(), {:messages, &1})
             )

    assert_receive {:tail, %{chunk: "!", phase: "final_answer", output_index: 1}}
    refute_receive {:tail, %{chunk: "hello!", output_index: 0}}
    refute_receive {:messages, _}

    assert :ok = StreamTracker.stop(tracker)
  end

  test "user on_chunk keeps its text-only callback and progress semantics" do
    tracker = StreamTracker.start(true)

    opts = [
      on_chunk: &send(self(), {:user_chunk, &1}),
      on_progress: &send(self(), {:progress, &1})
    ]

    callback =
      StreamTracker.callback(tracker, true, opts, fn payload ->
        send(self(), {:delta, payload})
      end)

    callback.(%{text: "answer", phase: "final_answer", output_index: 0})

    assert_receive {:user_chunk, "answer"}
    assert_receive {:progress, :message_delta}
    refute_receive {:delta, _}
    assert StreamTracker.emitted?(tracker)

    assert :ok = StreamTracker.stop(tracker)
  end

  test "late provider chunks after tracker shutdown are ignored safely" do
    tracker = StreamTracker.start(true)
    callback = StreamTracker.callback(tracker, true, [], fn _payload -> :ok end)

    assert :ok = StreamTracker.stop(tracker)
    assert :ok = callback.("late")
  end

  test "non-streaming completion delegates the full message batch" do
    messages = [Message.assistant("complete")]

    assert :ok =
             StreamTracker.emit_completion(
               false,
               nil,
               StreamTracker.snapshot(nil),
               messages,
               &send(self(), {:delta, &1}),
               &send(self(), {:messages, &1})
             )

    assert_receive {:messages, ^messages}
    refute_receive {:delta, _}
  end
end
