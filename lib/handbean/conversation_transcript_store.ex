defmodule Handbean.ConversationTranscriptStore do
  @moduledoc """
  Conversation transcript persistence boundary.

  The transcript is the durable, cross-channel conversation history. LiveView,
  SNS, webhook, CLI, and future channels should all read/write through this
  module instead of treating a UI timeline assign as the owner of history.
  """

  @type entry :: map()

  @callback list(String.t(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  @callback page(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback complete_tool_call(String.t(), entry(), entry() | nil, [String.t()], keyword()) ::
              {:ok, %{tool_entry: entry(), media_entry: entry() | nil}} | {:error, term()}
  @callback consume(String.t(), [String.t()], map(), keyword()) :: :ok | {:error, term()}
  @callback append(String.t(), entry(), keyword()) :: {:ok, entry()} | {:error, term()}
  @callback append_many(String.t(), [entry()], keyword()) :: {:ok, [entry()]} | {:error, term()}
  @callback interrupt_workspace_commands(String.t(), keyword()) ::
              {:ok, [String.t()]} | {:error, term()}
  @callback pending_workspace_command_responses(keyword()) ::
              {:ok, [{String.t(), entry()}]} | {:error, term()}
  @callback claim_workspace_command_response(String.t(), String.t(), String.t(), keyword()) ::
              {:ok, entry()} | {:error, term()}
  @callback update(String.t(), String.t(), map(), keyword()) :: {:ok, entry()} | {:error, term()}
  @callback append_content(String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
              {:ok, %{id: String.t(), text_bytes: non_neg_integer()}} | {:error, term()}
  @callback delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback replace_all(String.t(), [entry()], keyword()) :: :ok | {:error, term()}
  @optional_callbacks page: 2,
                      complete_tool_call: 5,
                      consume: 4,
                      append_content: 5,
                      append_many: 3,
                      interrupt_workspace_commands: 2,
                      pending_workspace_command_responses: 1,
                      claim_workspace_command_response: 4

  @doc "Load all transcript entries for a conversation."
  @spec list(String.t(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  def list(conversation_id, opts \\ []) when is_binary(conversation_id) do
    impl(opts).list(conversation_id, opts)
  end

  @doc """
  Read a bounded history page in chronological order, newest page by default.

  `:limit` is 1..200 (default 100). Pass the returned `:before` entry ID to
  load the preceding page. A deleted cursor returns `:invalid_cursor`; restart
  from the newest page rather than silently skipping history. Full `list/2`
  remains available for runtime context/recovery and legacy adapters.
  """
  def page(conversation_id, opts \\ []) when is_binary(conversation_id) do
    store = impl(opts)

    if Code.ensure_loaded?(store) and function_exported?(store, :page, 2),
      do: store.page(conversation_id, opts),
      else: {:error, :pagination_not_supported}
  end

  @doc "Append one transcript entry, filling common fields when absent."
  @spec append(String.t(), entry(), keyword()) :: {:ok, entry()} | {:error, term()}
  def append(conversation_id, entry, opts \\ [])
      when is_binary(conversation_id) and is_map(entry) do
    impl(opts).append(conversation_id, entry, opts)
  end

  @doc "Atomically append an ordered batch of transcript entries."
  @spec append_many(String.t(), [entry()], keyword()) :: {:ok, [entry()]} | {:error, term()}
  def append_many(conversation_id, entries, opts \\ [])
      when is_binary(conversation_id) and is_list(entries) do
    store = impl(opts)

    if Code.ensure_loaded?(store) and function_exported?(store, :append_many, 3),
      do: store.append_many(conversation_id, entries, opts),
      else: {:error, :unsupported}
  end

  @doc false
  @spec interrupt_workspace_commands(String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def interrupt_workspace_commands(error, opts \\ []) when is_binary(error) do
    store = impl(opts)

    if Code.ensure_loaded?(store) and function_exported?(store, :interrupt_workspace_commands, 2),
      do: store.interrupt_workspace_commands(error, opts),
      else: {:error, :unsupported}
  end

  @doc false
  @spec pending_workspace_command_responses(keyword()) ::
          {:ok, [{String.t(), entry()}]} | {:error, term()}
  def pending_workspace_command_responses(opts \\ []) do
    store = impl(opts)

    if Code.ensure_loaded?(store) and
         function_exported?(store, :pending_workspace_command_responses, 1),
       do: store.pending_workspace_command_responses(opts),
       else: {:error, :unsupported}
  end

  @doc false
  @spec claim_workspace_command_response(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, entry()} | {:error, term()}
  def claim_workspace_command_response(conversation_id, entry_id, attempt_id, opts \\ [])
      when is_binary(conversation_id) and is_binary(entry_id) and is_binary(attempt_id) do
    store = impl(opts)

    if Code.ensure_loaded?(store) and
         function_exported?(store, :claim_workspace_command_response, 4),
       do: store.claim_workspace_command_response(conversation_id, entry_id, attempt_id, opts),
       else: {:error, :unsupported}
  end

  @doc "Patch one transcript entry by id."
  @spec update(String.t(), String.t(), map(), keyword()) :: {:ok, entry()} | {:error, term()}
  def update(conversation_id, entry_id, patch, opts \\ [])
      when is_binary(conversation_id) and is_binary(entry_id) and is_map(patch) do
    impl(opts).update(conversation_id, entry_id, patch, opts)
  end

  @doc false
  @spec append_content(String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, %{id: String.t(), text_bytes: non_neg_integer()}} | {:error, term()}
  def append_content(conversation_id, entry_id, delta, status, opts \\ [])
      when is_binary(conversation_id) and is_binary(entry_id) and is_binary(delta) do
    store = impl(opts)

    if Code.ensure_loaded?(store) and function_exported?(store, :append_content, 5) do
      store.append_content(conversation_id, entry_id, delta, status, opts)
    else
      patch = %{"content" => %{"$append" => delta}}
      patch = if is_binary(status), do: Map.put(patch, "status", status), else: patch

      case store.update(conversation_id, entry_id, patch, opts) do
        {:ok, entry} ->
          {:ok, %{id: entry["id"], text_bytes: byte_size(entry["content"] || "")}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Mark inbound entries consumed and move them to the end in `ids` order.

  Send order can differ from enqueue order: a follow_up sits in the transcript
  while later run entries are appended, then becomes the next user turn.
  Adapters without `consume/4` patch in place and keep the original sequence.
  """
  @spec consume(String.t(), [String.t()], map(), keyword()) :: :ok | {:error, term()}
  def consume(conversation_id, ids, patch, opts \\ [])
      when is_binary(conversation_id) and is_list(ids) and is_map(patch) do
    store = impl(opts)

    if Code.ensure_loaded?(store) and function_exported?(store, :consume, 4) do
      store.consume(conversation_id, ids, patch, opts)
    else
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case update(conversation_id, id, patch, opts) do
          {:ok, _entry} -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Delete one entry atomically with respect to other transcript writes. Missing ids are a no-op."
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(conversation_id, entry_id, opts \\ [])
      when is_binary(conversation_id) and is_binary(entry_id) do
    impl(opts).delete(conversation_id, entry_id, opts)
  end

  @doc "Replace the complete transcript for a conversation."
  @spec replace_all(String.t(), [entry()], keyword()) :: :ok | {:error, term()}
  def replace_all(conversation_id, entries, opts \\ [])
      when is_binary(conversation_id) and is_list(entries) do
    impl(opts).replace_all(conversation_id, entries, opts)
  end

  @doc "Return the configured transcript store implementation."
  def impl(opts \\ []) do
    Keyword.get(opts, :transcript_store) ||
      Application.get_env(:handbean, :conversation_transcript_store, __MODULE__.ConversationStore)
  end
end
