defmodule Handbean.Agent.SecretMasking.StreamRestorerTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.SecretMasking.StreamRestorer

  @placeholder "{{API_KEY_abcdefgh}}"
  @secret "sk-proj-abcdefghijklmnopqrstuvwxyz123456"

  test "restores placeholders split across chunks without reordering interleaved channels" do
    state = StreamRestorer.new(%{@placeholder => @secret})

    {state, []} =
      StreamRestorer.push(state, :chunk, %{
        text: "first {{API_",
        phase: "commentary",
        output_index: 0
      })

    {state, []} =
      StreamRestorer.push(state, :chunk, %{
        text: "second",
        phase: "final_answer",
        output_index: 1
      })

    {state, outputs} =
      StreamRestorer.push(state, :chunk, %{
        text: "KEY_abcdefgh}} tail",
        phase: "commentary",
        output_index: 0
      })

    assert outputs == [
             {:chunk, %{text: "first ", phase: "commentary", output_index: 0}},
             {:chunk, %{text: "second", phase: "final_answer", output_index: 1}},
             {:chunk, %{text: @secret <> " tail", phase: "commentary", output_index: 0}}
           ]

    assert {:ok, _state, []} = StreamRestorer.finish(state)
  end

  test "shares global ordering between text chunks and thinking events" do
    state = StreamRestorer.new(%{@placeholder => @secret})
    {state, []} = StreamRestorer.push(state, :event, {:thinking_delta, "think {{API_"})
    {state, []} = StreamRestorer.push(state, :chunk, "visible")

    {_state, outputs} =
      StreamRestorer.push(state, :event, {:thinking_delta, "KEY_abcdefgh}}"})

    assert outputs == [
             {:event, {:thinking_delta, "think "}},
             {:chunk, "visible"},
             {:event, {:thinking_delta, @secret}}
           ]
  end

  test "restores a reformatted placeholder split across chunks" do
    state = StreamRestorer.new(%{@placeholder => @secret})
    {state, []} = StreamRestorer.push(state, :chunk, "before API_KEY_ab")

    {state, outputs} = StreamRestorer.push(state, :chunk, "CDEFGH after")

    assert outputs == [{:chunk, "before "}, {:chunk, @secret <> " after"}]
    assert {:ok, _state, []} = StreamRestorer.finish(state)
  end

  test "restores a complete unbraced placeholder when the stream finishes" do
    state = StreamRestorer.new(%{@placeholder => @secret})
    {state, []} = StreamRestorer.push(state, :chunk, "before API_KEY_abcdefgh")

    assert {:ok, _state, [{:chunk, "before " <> @secret}]} = StreamRestorer.finish(state)
  end

  test "flushes an unfinished non-placeholder tail unchanged" do
    state = StreamRestorer.new(%{@placeholder => @secret})
    {state, []} = StreamRestorer.push(state, :chunk, "text {{API_")

    assert {:ok, _state, [{:chunk, "text {{API_"}]} = StreamRestorer.finish(state)
  end

  test "fails closed when unresolved events exceed the buffer bound" do
    state = StreamRestorer.new(%{@placeholder => @secret}, max_events: 1)
    {state, []} = StreamRestorer.push(state, :chunk, "{{API_")
    {state, []} = StreamRestorer.push(state, :event, :later_event)

    assert StreamRestorer.error(state) == :secret_masking_stream_buffer_exceeded
    assert {:error, :secret_masking_stream_buffer_exceeded} = StreamRestorer.finish(state)
  end
end
