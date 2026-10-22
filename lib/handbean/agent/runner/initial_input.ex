defmodule Handbean.Agent.Runner.InitialInput do
  @moduledoc """
  Accepts the initial message before a run starts its provider task.

  Runs inside the Runner's exclusive start gate. The candidate queue reservation
  and transcript acknowledgement must complete before the task can consume input.
  """

  alias Handbean.Agent.{CandidateQueue, Message, OperationReceipt, TranscriptPersistence}
  alias Handbean.ConversationStore

  @spec accept(pid(), String.t(), String.t() | Message.t(), keyword()) ::
          {:ok, String.t() | Message.t(), keyword()} | {:error, term()}
  def accept(queue_pid, conversation_id, content, opts) do
    with :ok <- CandidateQueue.begin_initial(queue_pid, opts),
         {:ok, _content, _opts} = accepted <- accept_inbound(conversation_id, content, opts),
         :ok <- CandidateQueue.commit_initial(queue_pid, opts) do
      accepted
    else
      {:error, _reason} = error ->
        :ok = CandidateQueue.abort_initial(queue_pid, opts)
        error
    end
  end

  defp accept_inbound(conversation_id, content, opts) do
    receipt = %{action: :started, run_id: Keyword.fetch!(opts, :run_id)}

    if Keyword.get(opts, :persist_inbound?, true) do
      inbound_opts = Keyword.put(opts, :deliver_as, :new_run)

      case TranscriptPersistence.accept_inbound(conversation_id, content, receipt, inbound_opts) do
        {:ok, entry} ->
          {content, opts} = align_inbound(content, opts, entry)
          {:ok, content, opts}

        :ok ->
          {:ok, content, opts}

        {:error, reason} ->
          {:error, reason}
      end
    else
      with true <- ConversationStore.active?(conversation_id),
           :ok <-
             OperationReceipt.complete({:message, conversation_id}, opts[:request_id], receipt) do
        {:ok, content, opts}
      else
        false -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp align_inbound(content, opts, %{"id" => id}) when is_binary(id) do
    previous = opts[:transcript_id] || opts[:message_id]

    cond do
      previous == id ->
        {content, opts}

      is_nil(previous) ->
        {content, Keyword.merge(opts, message_id: id, transcript_id: id)}

      true ->
        content =
          case content do
            %Message{} = message -> %{message | id: id}
            other -> other
          end

        opts = Keyword.merge(opts, message_id: id, transcript_id: id, inbound_id: id)
        {content, opts}
    end
  end

  defp align_inbound(content, opts, _entry), do: {content, opts}
end
