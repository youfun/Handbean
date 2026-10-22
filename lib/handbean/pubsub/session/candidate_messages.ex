defmodule Handbean.PubSub.Session.CandidateMessages do
  @moduledoc """
  Adapts candidate message identities and pending-message views for Session.

  CandidateQueue remains the owner of active-run queues. Session owns next-turn
  messages and decides when to read or seal the active queue. This adapter keeps
  no state and preserves the bounded read used during client recovery.
  """

  alias Handbean.Agent.{CandidateQueue, Message}

  @pending_queue_timeout_ms 100

  @doc false
  @spec stamp_ids(term(), keyword()) :: {term(), keyword()}
  def stamp_ids(content, opts) do
    struct_id =
      case content do
        %Message{id: id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    opt_message_id = present_id(Keyword.get(opts, :message_id))
    opt_transcript_id = present_id(Keyword.get(opts, :transcript_id))
    canonical = opt_message_id || opt_transcript_id || struct_id || Ecto.UUID.generate()

    content =
      case content do
        %Message{} = message -> %{message | id: canonical}
        other -> other
      end

    {content, Keyword.put(opts, :message_id, canonical)}
  end

  @doc false
  @spec normalize(Message.t() | String.t(), keyword()) :: Message.t()
  def normalize(%Message{} = message, opts) do
    %{message | id: message.id || Keyword.get(opts, :message_id)}
  end

  def normalize(content, opts) when is_binary(content) do
    %Message{role: :user, content: content, id: Keyword.get(opts, :message_id)}
  end

  @doc false
  @spec text(term()) :: String.t()
  def text(%Message{} = message), do: Message.text(message) || ""
  def text(content) when is_binary(content), do: content
  def text(content), do: inspect(content)

  @doc false
  @spec pending(pid() | nil, [Message.t()]) :: [map()]
  def pending(queue_pid, next_turn_messages) do
    queue_messages = pending_queue(queue_pid)
    next_turn_messages = Enum.map(next_turn_messages, &pending_message(&1, :next_turn))
    queue_messages ++ next_turn_messages
  end

  @doc false
  @spec seal(pid() | nil) :: :ok
  def seal(queue_pid) when is_pid(queue_pid) do
    CandidateQueue.seal(queue_pid)
  catch
    :exit, _reason -> :ok
  end

  def seal(_queue_pid), do: :ok

  defp pending_queue(nil), do: []

  defp pending_queue(queue_pid) do
    queue_pid
    |> CandidateQueue.get_messages(@pending_queue_timeout_ms)
    |> Enum.map(fn %{message: message, metadata: meta} ->
      pending_message(message, meta.deliver_as)
    end)
  catch
    :exit, _reason -> []
  end

  defp pending_message(message, deliver_as) do
    %{id: message.id, content: message.content, role: message.role, deliver_as: deliver_as}
  end

  defp present_id(id) when is_binary(id) and id != "", do: id
  defp present_id(_id), do: nil
end
