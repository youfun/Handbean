defmodule Handbean.Agent.SecretMasking.StreamRestorer do
  @moduledoc false

  alias Handbean.Agent.SecretMasking

  @default_max_events 512
  @default_max_bytes 1_048_576

  defstruct restore: %{},
            next_sequence: 0,
            order: :queue.new(),
            items: %{},
            channels: %{},
            buffered_bytes: 0,
            max_events: @default_max_events,
            max_bytes: @default_max_bytes,
            error: nil

  @type source :: :chunk | :event
  @type output :: {source(), term()}
  @type t :: %__MODULE__{}

  def new(restore, opts \\ []) when is_map(restore) do
    %__MODULE__{
      restore: restore,
      max_events: Keyword.get(opts, :max_events, @default_max_events),
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
    }
  end

  @spec push(t(), source(), term()) :: {t(), [output()]}
  def push(%__MODULE__{error: error} = state, _source, _event) when not is_nil(error),
    do: {state, []}

  def push(%__MODULE__{} = state, source, event) when source in [:chunk, :event] do
    case classify(source, event) do
      {:text, channel, text} -> push_text(state, source, event, channel, text)
      :passthrough -> enqueue_ready(state, source, event, 0)
      {:error, reason} -> {%{state | error: reason}, []}
    end
  end

  @spec finish(t()) :: {:ok, t(), [output()]} | {:error, term()}
  def finish(%__MODULE__{error: reason}) when not is_nil(reason), do: {:error, reason}

  def finish(%__MODULE__{} = state) do
    state =
      Enum.reduce(state.channels, state, fn {_channel, %{sequence: sequence, tail: tail}}, acc ->
        update_item(acc, sequence, fn item ->
          restored_tail = SecretMasking.restore(tail, state.restore)

          %{
            item
            | event: put_text(item.source, item.event, item.text <> restored_tail),
              text: item.text <> restored_tail,
              ready?: true
          }
        end)
      end)

    {state, ready} = release_ready(%{state | channels: %{}})
    {:ok, state, ready}
  end

  @spec error(t()) :: term() | nil
  def error(%__MODULE__{error: error}), do: error

  defp push_text(state, source, event, channel, text) do
    case Map.pop(state.channels, channel) do
      {nil, channels} ->
        push_new_text(%{state | channels: channels}, source, event, channel, text)

      {%{sequence: previous_sequence, tail: carry}, channels} ->
        state =
          state
          |> Map.put(:channels, channels)
          |> update_item(previous_sequence, &%{&1 | ready?: true})

        push_continuation(state, source, event, channel, carry <> text, byte_size(text))
    end
  end

  defp push_new_text(state, source, event, channel, text) do
    tail_length = SecretMasking.partial_placeholder_length(text, state.restore)
    stable_length = byte_size(text) - tail_length
    stable = binary_part(text, 0, stable_length)
    tail = binary_part(text, stable_length, tail_length)
    restored = SecretMasking.restore(stable, state.restore)
    ready? = tail == ""

    {state, sequence} =
      enqueue(state, source, put_text(source, event, restored), restored, ready?, byte_size(text))

    state =
      if ready?,
        do: state,
        else: put_in(state.channels[channel], %{sequence: sequence, tail: tail})

    release_or_fail(state)
  end

  defp push_continuation(state, source, event, channel, combined, input_bytes) do
    tail_length = SecretMasking.partial_placeholder_length(combined, state.restore)
    stable_length = byte_size(combined) - tail_length
    stable = binary_part(combined, 0, stable_length)
    tail = binary_part(combined, stable_length, tail_length)
    restored = SecretMasking.restore(stable, state.restore)
    ready? = tail == ""

    {state, sequence} =
      enqueue(state, source, put_text(source, event, restored), restored, ready?, input_bytes)

    state =
      if ready?,
        do: state,
        else: put_in(state.channels[channel], %{sequence: sequence, tail: tail})

    release_or_fail(state)
  end

  defp enqueue_ready(state, source, event, bytes) do
    {state, _sequence} = enqueue(state, source, event, nil, true, bytes)
    release_or_fail(state)
  end

  defp enqueue(state, source, event, text, ready?, bytes) do
    sequence = state.next_sequence
    item = %{source: source, event: event, text: text, ready?: ready?, bytes: bytes}

    state = %{
      state
      | next_sequence: sequence + 1,
        order: :queue.in(sequence, state.order),
        items: Map.put(state.items, sequence, item),
        buffered_bytes: state.buffered_bytes + bytes
    }

    {state, sequence}
  end

  defp release_or_fail(state) do
    if map_size(state.items) > state.max_events or state.buffered_bytes > state.max_bytes do
      {%{state | error: :secret_masking_stream_buffer_exceeded}, []}
    else
      release_ready(state)
    end
  end

  defp release_ready(state), do: release_ready(state, [])

  defp release_ready(state, ready) do
    case :queue.peek(state.order) do
      {:value, sequence} ->
        case Map.fetch!(state.items, sequence) do
          %{ready?: true} = item ->
            {{:value, ^sequence}, order} = :queue.out(state.order)

            state = %{
              state
              | order: order,
                items: Map.delete(state.items, sequence),
                buffered_bytes: max(state.buffered_bytes - item.bytes, 0)
            }

            output = if empty_text?(item), do: ready, else: [{item.source, item.event} | ready]
            release_ready(state, output)

          %{ready?: false} ->
            {state, Enum.reverse(ready)}
        end

      :empty ->
        {state, Enum.reverse(ready)}
    end
  end

  defp update_item(state, sequence, fun) do
    %{state | items: Map.update!(state.items, sequence, fun)}
  end

  defp classify(:chunk, text) when is_binary(text), do: {:text, {:chunk, :default}, text}

  defp classify(:chunk, %{text: text, output_index: index})
       when is_binary(text) and is_integer(index),
       do: {:text, {:chunk, index}, text}

  defp classify(:chunk, _event), do: {:error, :unsupported_secret_masking_stream_chunk}

  defp classify(:event, {:thinking_delta, text}) when is_binary(text),
    do: {:text, :thinking, text}

  defp classify(:event, _event), do: :passthrough

  defp put_text(:chunk, text, replacement) when is_binary(text), do: replacement
  defp put_text(:chunk, event, replacement) when is_map(event), do: %{event | text: replacement}
  defp put_text(:event, {:thinking_delta, _text}, replacement), do: {:thinking_delta, replacement}

  defp empty_text?(%{text: text}) when is_binary(text), do: text == ""
  defp empty_text?(_item), do: false
end
