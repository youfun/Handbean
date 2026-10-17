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
  @optional_callbacks page: 2
  @callback append(String.t(), entry(), keyword()) :: {:ok, entry()} | {:error, term()}
  @callback update(String.t(), String.t(), map(), keyword()) :: {:ok, entry()} | {:error, term()}
  @callback delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback replace_all(String.t(), [entry()], keyword()) :: :ok | {:error, term()}

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

  @doc "Patch one transcript entry by id."
  @spec update(String.t(), String.t(), map(), keyword()) :: {:ok, entry()} | {:error, term()}
  def update(conversation_id, entry_id, patch, opts \\ [])
      when is_binary(conversation_id) and is_binary(entry_id) and is_map(patch) do
    impl(opts).update(conversation_id, entry_id, patch, opts)
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
