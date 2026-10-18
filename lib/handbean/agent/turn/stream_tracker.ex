defmodule Handbean.Agent.Turn.StreamTracker do
  @moduledoc """
  Owns the ephemeral state used to reconcile provider stream chunks with the
  final assistant messages.

  A tracker records whether any visible chunk was emitted and aggregates text
  per provider output block. It is stopped after every provider invocation;
  the immutable snapshot is then used to emit only an unstreamed final tail.
  """

  alias Handbean.Agent.Message

  require Logger

  defstruct [:chunk_counter, :text_agent]

  @type snapshot :: %{text: String.t(), phases: map()}
  @opaque t :: %__MODULE__{chunk_counter: reference(), text_agent: pid()}

  @spec start(boolean()) :: t() | nil
  def start(false), do: nil

  def start(true) do
    {:ok, text_agent} = Agent.start_link(fn -> %{text: "", phases: %{}} end)
    %__MODULE__{chunk_counter: :counters.new(1, []), text_agent: text_agent}
  end

  @doc "Build the provider callback while preserving the existing user callback contract."
  @spec callback(t() | nil, boolean(), keyword(), (map() -> any())) ::
          (term() -> any()) | nil
  def callback(tracker, streaming?, opts, emit_delta)
      when is_list(opts) and is_function(emit_delta, 1) do
    case Keyword.get(opts, :on_chunk) do
      user_on_chunk when is_function(user_on_chunk, 1) ->
        fn chunk ->
          track(tracker, chunk)
          notify_progress(opts)
          user_on_chunk.(chunk_text(chunk))
        end

      _ when streaming? ->
        fn chunk ->
          track(tracker, chunk)
          emit_chunk(emit_delta, chunk)
        end

      _ ->
        nil
    end
  end

  @spec snapshot(t() | nil) :: snapshot()
  def snapshot(nil), do: empty_snapshot()

  def snapshot(%__MODULE__{text_agent: text_agent}) do
    case Agent.get(text_agent, & &1) do
      %{text: text, phases: phases} = streamed when is_binary(text) and is_map(phases) ->
        streamed

      text when is_binary(text) ->
        %{text: text, phases: %{}}

      _ ->
        empty_snapshot()
    end
  end

  @spec stop(t() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%__MODULE__{text_agent: text_agent}) do
    Agent.stop(text_agent)
  catch
    :exit, _reason -> :ok
  end

  @spec emitted?(t() | nil) :: boolean()
  def emitted?(nil), do: false
  def emitted?(%__MODULE__{chunk_counter: counter}), do: :counters.get(counter, 1) > 0

  @doc "Emit a non-streamed response or only the tail missing from streamed chunks."
  @spec emit_completion(
          boolean(),
          t() | nil,
          snapshot(),
          [Message.t()],
          (map() -> any()),
          ([Message.t()] -> any())
        ) :: :ok
  def emit_completion(false, _tracker, _snapshot, messages, _emit_delta, emit_messages) do
    Logger.debug("[Turn] emitting completion messages non_streaming count=#{length(messages)}")
    emit_messages.(messages)
    :ok
  end

  def emit_completion(true, tracker, snapshot, messages, emit_delta, emit_messages) do
    if emitted?(tracker) do
      emit_streaming_tail(messages, snapshot, emit_delta)
    else
      Logger.debug(
        "[Turn] streaming produced no chunks; emitting final messages count=#{length(messages)}"
      )

      emit_messages.(messages)
    end

    :ok
  end

  defp empty_snapshot, do: %{text: "", phases: %{}}

  defp track(nil, _chunk), do: :ok

  defp track(%__MODULE__{} = tracker, chunk) do
    text = chunk_text(chunk)
    if text != "", do: :counters.add(tracker.chunk_counter, 1, 1)
    track_text(tracker.text_agent, chunk)
  end

  defp chunk_text(%{text: text}) when is_binary(text), do: text
  defp chunk_text(text) when is_binary(text), do: text
  defp chunk_text(_chunk), do: ""

  defp track_text(_agent, ""), do: :ok

  defp track_text(agent, chunk) when is_binary(chunk) do
    safe_update(agent, fn streamed -> %{streamed | text: streamed.text <> chunk} end)
  end

  defp track_text(agent, %{text: text, phase: phase, output_index: index})
       when is_binary(text) and is_integer(index) do
    safe_update(agent, fn streamed ->
      phases =
        Map.update(streamed.phases, index, %{phase: phase, text: text}, fn current ->
          %{current | phase: phase, text: current.text <> text}
        end)

      %{streamed | text: streamed.text <> text, phases: phases}
    end)
  end

  defp track_text(_agent, _chunk), do: :ok

  defp safe_update(agent, update) do
    Agent.update(agent, update)
  catch
    :exit, _reason -> :ok
  end

  defp emit_chunk(emit_delta, %{text: text, phase: phase, output_index: index})
       when is_binary(text) and text != "" and is_integer(index) do
    emit_delta.(%{chunk: text, phase: phase, output_index: index})
  end

  defp emit_chunk(emit_delta, chunk) when is_binary(chunk) and chunk != "" do
    emit_delta.(%{chunk: chunk})
  end

  defp emit_chunk(_emit_delta, _chunk), do: :ok

  defp notify_progress(opts) do
    case Keyword.get(opts, :on_progress) do
      fun when is_function(fun, 1) -> fun.(:message_delta)
      _ -> :ok
    end
  end

  defp emit_streaming_tail(messages, %{phases: phases}, emit_delta)
       when map_size(phases) > 0 do
    messages
    |> indexed_text_blocks()
    |> Enum.each(fn {index, block} ->
      streamed_block = Map.get(phases, index, %{text: "", phase: nil})
      emit_unstreamed_tail(block, streamed_block, index, emit_delta)
    end)
  end

  defp emit_streaming_tail(messages, %{text: streamed}, emit_delta) do
    final_text =
      messages
      |> Enum.filter(&match?(%Message{role: :assistant}, &1))
      |> Enum.map_join(fn message -> Message.text(message) || "" end)

    emit_text_tail(final_text, streamed, nil, emit_delta)
  end

  defp content_blocks(%Message{content: blocks}) when is_list(blocks), do: blocks

  defp content_blocks(%Message{content: text}) when is_binary(text),
    do: [%{type: "text", text: text}]

  defp content_blocks(_message), do: []

  defp indexed_text_blocks(messages) do
    messages
    |> Enum.filter(&match?(%Message{role: :assistant}, &1))
    |> Enum.flat_map(&content_blocks/1)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{type: "text", text: text} = block, position}, indexed when is_binary(text) ->
        index = output_index(block, position)

        Map.update(indexed, index, block, fn current ->
          %{current | text: current.text <> text}
        end)

      {_block, _position}, indexed ->
        indexed
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp output_index(%{output_index: index}, _position) when is_integer(index), do: index
  defp output_index(_block, position), do: position

  defp emit_unstreamed_tail(block, streamed_block, index, emit_delta) do
    phase = block[:phase] || streamed_block[:phase]

    cond do
      streamed_block.text == "" ->
        emit_delta.(stream_payload(block.text, phase, index))

      streamed_block.text == block.text ->
        :ok

      String.starts_with?(block.text, streamed_block.text) ->
        tail =
          binary_part(
            block.text,
            byte_size(streamed_block.text),
            byte_size(block.text) - byte_size(streamed_block.text)
          )

        emit_delta.(stream_payload(tail, phase, index))

      true ->
        Logger.debug(
          "[Turn] streaming assistant text diverged from chunks; keeping streamed text"
        )
    end
  end

  defp emit_text_tail("", _streamed, _phase, _emit_delta), do: :ok

  defp emit_text_tail(final_text, streamed, _phase, _emit_delta) when final_text == streamed do
    Logger.debug("[Turn] streaming chunks already match final assistant text; skip replay")
  end

  defp emit_text_tail(final_text, streamed, phase, emit_delta) when is_binary(streamed) do
    if String.starts_with?(final_text, streamed) do
      tail =
        binary_part(
          final_text,
          byte_size(streamed),
          byte_size(final_text) - byte_size(streamed)
        )

      emit_delta.(stream_payload(tail, phase, nil))
    else
      Logger.debug(
        "[Turn] streaming final assistant text diverged from streamed chunks; keeping streamed text"
      )
    end
  end

  defp emit_text_tail(_final_text, _streamed, _phase, _emit_delta), do: :ok

  defp stream_payload(text, phase, index) do
    payload = %{chunk: text}
    payload = if is_binary(phase), do: Map.put(payload, :phase, phase), else: payload
    if is_integer(index), do: Map.put(payload, :output_index, index), else: payload
  end
end
