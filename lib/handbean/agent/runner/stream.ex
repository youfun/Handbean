defmodule Handbean.Agent.Runner.Stream do
  @moduledoc """
  Run-local stream persistence policy, evaluated in the Runner process.

  The Runner owns this value and handles its timer messages. A flush clears the
  batch before writing so that failures cannot replay already accepted text.
  """

  alias Handbean.Agent.Runner.Events
  alias Handbean.Agent.StreamBatch

  @enforce_keys [:batch]
  defstruct [:batch, started?: false]

  @type t :: %__MODULE__{batch: StreamBatch.t(), started?: boolean()}
  @type result :: {:ok, t()} | {:error, term(), t()}

  @spec new(keyword()) :: t()
  def new(opts), do: %__MODULE__{batch: StreamBatch.new(opts)}

  @spec resume(t()) :: t()
  def resume(%__MODULE__{} = stream), do: %{stream | started?: false}

  @spec timer_matches?(t(), reference()) :: boolean()
  def timer_matches?(%__MODULE__{batch: %{timer: {_ref, token}}}, token), do: true
  def timer_matches?(%__MODULE__{}, _token), do: false

  @spec persist(t(), {atom(), term()}, String.t(), keyword()) :: result()
  def persist(stream, {:message_delta, payload} = event, conversation_id, opts)
      when is_map(payload) do
    cond do
      enriched_delta?(payload) ->
        case persist_after_flush(stream, event, conversation_id, opts) do
          {:ok, projected, stream} -> {:ok, %{stream | started?: visible_delta?(projected)}}
          {:error, reason, stream} -> {:error, reason, stream}
        end

      empty_chunk?(payload) ->
        {:ok, stream}

      true ->
        queue(stream, event, conversation_id, opts)
    end
  end

  def persist(stream, event, conversation_id, opts) do
    stream = %{stream | started?: false}

    case persist_after_flush(stream, event, conversation_id, opts) do
      {:ok, _projected, stream} -> {:ok, stream}
      {:error, reason, stream} -> {:error, reason, stream}
    end
  end

  @spec flush(t(), String.t(), keyword()) :: result()
  def flush(%__MODULE__{batch: batch} = stream, conversation_id, opts) do
    cancel_timer(batch.timer)
    stream = %{stream | batch: StreamBatch.reset(batch)}

    if StreamBatch.empty?(batch) do
      {:ok, stream}
    else
      case Events.persist(conversation_id, StreamBatch.event(batch), opts) do
        {:ok, _projected} -> {:ok, stream}
        {:error, reason} -> {:error, reason, stream}
      end
    end
  end

  @spec discard(t()) :: t()
  def discard(%__MODULE__{} = stream) do
    cancel_timer(stream.batch.timer)
    %{stream | batch: StreamBatch.reset(stream.batch)}
  end

  defp queue(%{started?: false} = stream, event, conversation_id, opts) do
    case Events.persist(conversation_id, event, opts) do
      {:ok, projected} -> {:ok, %{stream | started?: visible_delta?(projected)}}
      {:error, reason} -> {:error, reason, stream}
    end
  end

  defp queue(stream, {:message_delta, payload}, conversation_id, opts) do
    case StreamBatch.append(stream.batch, payload) do
      {:boundary, _batch} ->
        with {:ok, stream} <- flush(stream, conversation_id, opts) do
          queue(%{stream | started?: false}, {:message_delta, payload}, conversation_id, opts)
        end

      {:ok, batch} ->
        batch = if StreamBatch.empty?(batch), do: batch, else: maybe_arm_timer(batch)
        stream = %{stream | batch: batch}

        if StreamBatch.full?(batch), do: flush(stream, conversation_id, opts), else: {:ok, stream}
    end
  end

  defp persist_after_flush(stream, event, conversation_id, opts) do
    case flush(stream, conversation_id, opts) do
      {:ok, stream} ->
        case Events.persist(conversation_id, event, opts) do
          {:ok, projected} -> {:ok, projected, stream}
          {:error, reason} -> {:error, reason, stream}
        end

      {:error, reason, stream} ->
        {:error, reason, stream}
    end
  end

  defp maybe_arm_timer(%StreamBatch{timer: nil} = batch) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:flush_stream_batch, token}, batch.max_wait_ms)
    %{batch | timer: {timer_ref, token}}
  end

  defp maybe_arm_timer(batch), do: batch

  defp cancel_timer({timer_ref, _token}) when is_reference(timer_ref),
    do: Process.cancel_timer(timer_ref)

  defp cancel_timer(_timer), do: false

  defp visible_delta?({:message_delta, payload}) do
    text = Map.get(payload, :text, Map.get(payload, "text"))
    is_binary(text) and text != ""
  end

  defp visible_delta?(_event), do: false

  defp empty_chunk?(payload) do
    Map.get(payload, :chunk, Map.get(payload, "chunk")) in [nil, ""]
  end

  defp enriched_delta?(payload) do
    Enum.any?([:thinking, :thinking_delta, :provider_items], fn key ->
      payload
      |> Map.get(key, Map.get(payload, Atom.to_string(key)))
      |> present_metadata?()
    end)
  end

  defp present_metadata?(value) when value in [nil, "", []], do: false
  defp present_metadata?(value) when is_map(value), do: map_size(value) > 0
  defp present_metadata?(_value), do: true
end
