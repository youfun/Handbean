defmodule Handbean.Conversations.UserSearch do
  @moduledoc """
  User-facing conversation discovery across authorized workspaces and free chat.

  This boundary is separate from Agent conversation-search tools. It searches
  only titles and settled user-visible message text, groups matches by
  conversation, and never exposes tool or internal transcript data.

  Pagination is a live activity keyset, not a snapshot. When a bounded scan
  pauses, its signed continuation records both the last completed conversation
  and the last checked entry in the current conversation. A later bounded call
  can therefore resume without skipping an unconfirmed conversation.
  """

  import Ecto.Query

  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEntry}

  @cursor_salt "user-conversation-search-page"
  @contents ~w(all title user assistant)
  @conversation_batch_size 50
  @default_max_conversations 500
  @default_max_entry_candidates 5_000
  @max_limit 20
  @snippet_radius 90

  defmodule Scope do
    @moduledoc """
    Server-created visibility scope for user-facing conversation search.

    Web clients never submit this structure. The authenticated server boundary
    creates it from the workspaces currently visible to the user.
    """

    @enforce_keys [:workspace_ids, :free?]
    defstruct [:workspace_ids, :free?]

    @type t :: %__MODULE__{workspace_ids: MapSet.t(String.t()), free?: boolean()}

    @doc false
    def new(workspace_ids, free?) when is_list(workspace_ids) and is_boolean(free?) do
      ids = Enum.filter(workspace_ids, &(is_binary(&1) and &1 != ""))
      %__MODULE__{workspace_ids: MapSet.new(ids), free?: free?}
    end
  end

  @type result :: %{
          results: [map()],
          next_cursor: String.t() | nil,
          incomplete: boolean(),
          consistency: :live
        }

  @doc "Search conversations within a trusted server-generated scope."
  @spec search(map(), Scope.t(), keyword()) :: {:ok, result()} | {:error, atom()}
  def search(input, scope, opts \\ [])

  def search(input, %Scope{} = scope, opts) when is_map(input) and is_list(opts) do
    with :ok <- validate_keys(input),
         {:ok, query} <- text(input, "query", "", 200),
         {:ok, content} <- content(input),
         {:ok, range} <- range(input, scope),
         {:ok, limit} <- integer(input, "limit", 12, 1, @max_limit),
         filters = %{query: String.trim(query), content: content, range: range},
         {:ok, cursor} <- decode_cursor(input["cursor"], filters, scope) do
      do_search(filters, scope, cursor, limit, opts)
    end
  end

  def search(_input, _scope, _opts), do: {:error, :invalid_input}

  @doc "Recheck that a conversation and optional entry remain inside the scope."
  @spec authorize_hit(Scope.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_accessible | :entry_unavailable}
  def authorize_hit(scope, conversation_id, entry_id \\ nil)

  def authorize_hit(%Scope{} = scope, conversation_id, entry_id)
      when is_binary(conversation_id) do
    case authorized_conversation(scope, conversation_id) do
      nil ->
        {:error, :not_accessible}

      conversation when is_nil(entry_id) ->
        {:ok, conversation_projection(conversation)}

      conversation when is_binary(entry_id) ->
        if searchable_entry_exists?(conversation_id, entry_id) do
          {:ok, conversation_projection(conversation)}
        else
          {:error, :entry_unavailable}
        end

      _conversation ->
        {:error, :entry_unavailable}
    end
  end

  def authorize_hit(_scope, _conversation_id, _entry_id), do: {:error, :not_accessible}

  defp do_search(filters, scope, cursor, limit, opts) do
    budgets = %{
      conversations: positive_budget(opts, :max_conversations, @default_max_conversations),
      entries: positive_budget(opts, :max_entry_candidates, @default_max_entry_candidates)
    }

    state = %{
      results: [],
      scanned_conversations: 0,
      scanned_entries: 0,
      cursor: cursor,
      paused: false,
      exhausted: false
    }

    case scan_batches(filters, scope, limit, budgets, state) do
      {:ok, state} ->
        results = Enum.reverse(state.results)

        next_cursor =
          if state.paused or (not state.exhausted and length(results) == limit) do
            encode_cursor(state.cursor, filters, scope)
          end

        {:ok,
         %{
           results: results,
           next_cursor: next_cursor,
           incomplete: state.paused,
           consistency: :live
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scan_batches(_filters, _scope, limit, _budgets, state)
       when length(state.results) >= limit,
       do: {:ok, state}

  defp scan_batches(_filters, _scope, _limit, budgets, state)
       when state.scanned_conversations >= budgets.conversations,
       do: {:ok, %{state | paused: true}}

  defp scan_batches(filters, scope, limit, budgets, state) do
    conversation_limit =
      min(@conversation_batch_size, budgets.conversations - state.scanned_conversations)

    with {:ok, conversations, more_conversations?} <-
           conversation_batch(filters, scope, state.cursor, conversation_limit),
         {:ok, scan} <-
           entries_for_batch(
             conversations,
             filters,
             state.cursor,
             budgets.entries - state.scanned_entries
           ) do
      next = reduce_batch(conversations, scan, filters, limit, state)
      next = %{next | scanned_entries: next.scanned_entries + scan.checked_count}

      cond do
        next.paused or length(next.results) >= limit ->
          {:ok, next}

        not more_conversations? ->
          {:ok, %{next | exhausted: true}}

        true ->
          scan_batches(filters, scope, limit, budgets, next)
      end
    end
  end

  defp reduce_batch(conversations, scan, filters, limit, state) do
    indexes =
      conversations
      |> Enum.with_index()
      |> Map.new(fn {row, index} -> {row.id, index} end)

    Enum.reduce_while(conversations, state, fn conversation, acc ->
      matches = Map.get(scan.matches, conversation.id, [])

      case conversation_scan_status(conversation, matches, scan, filters, indexes) do
        :complete ->
          cursor = %{completed: conversation_keyset(conversation), pending: nil}
          result = project_result(conversation, matches, filters)

          acc = %{
            acc
            | scanned_conversations: acc.scanned_conversations + 1,
              cursor: cursor,
              results: if(result, do: [result | acc.results], else: acc.results)
          }

          if length(acc.results) >= limit, do: {:halt, acc}, else: {:cont, acc}

        {:paused, nil} ->
          {:halt, %{acc | paused: true}}

        {:paused, entry_key} ->
          pending = %{
            conversation_id: conversation.id,
            selected_key: conversation_keyset(conversation),
            entry_key: entry_key
          }

          {:halt, %{acc | paused: true, cursor: %{acc.cursor | pending: pending}}}
      end
    end)
  end

  defp conversation_scan_status(conversation, matches, scan, filters, indexes) do
    cond do
      filters.query == "" or filters.content == "title" or title_match?(conversation, filters) ->
        :complete

      matches != [] ->
        :complete

      is_nil(scan.lookahead) ->
        :complete

      scan.lookahead.conversation_id == conversation.id ->
        checked = Map.get(scan.checked, conversation.id, [])
        {:paused, checked |> List.last() |> entry_key()}

      indexes[conversation.id] < indexes[scan.lookahead.conversation_id] ->
        :complete

      true ->
        {:paused, nil}
    end
  end

  defp conversation_batch(filters, scope, cursor, limit) do
    case cursor.pending do
      nil ->
        rows = conversation_rows(filters, scope, cursor.completed, limit + 1)
        {:ok, Enum.take(rows, limit), length(rows) > limit}

      pending ->
        with {:ok, current} <- pending_conversation(filters, scope, pending) do
          older_limit = max(limit - 1, 0)
          older = conversation_rows(filters, scope, pending.selected_key, older_limit + 1)
          {:ok, [current | Enum.take(older, older_limit)], length(older) > older_limit}
        end
    end
  end

  defp conversation_rows(filters, scope, keyset, limit) do
    Conversation
    |> where(
      [conversation],
      conversation.status == "active" and conversation.visibility == "user"
    )
    |> scope_filter(scope, filters.range)
    |> after_keyset(keyset)
    |> order_by([conversation], desc: conversation.updated_at, desc: conversation.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp pending_conversation(filters, scope, pending) do
    conversation =
      Conversation
      |> where(
        [conversation],
        conversation.id == ^pending.conversation_id and conversation.status == "active" and
          conversation.visibility == "user"
      )
      |> scope_filter(scope, filters.range)
      |> Repo.one()

    if conversation && conversation_keyset(conversation) == pending.selected_key,
      do: {:ok, conversation},
      else: {:error, :stale_or_invalid_cursor}
  end

  defp scope_filter(query, %Scope{} = scope, range) do
    workspace_ids = MapSet.to_list(scope.workspace_ids)
    free? = scope.free?

    condition =
      case range do
        :all ->
          dynamic(
            [conversation],
            (^free? and conversation.scope == "free") or
              (conversation.scope == "workspace" and conversation.workspace_id in ^workspace_ids)
          )

        :free ->
          dynamic([conversation], ^free? and conversation.scope == "free")

        {:workspace, workspace_id} ->
          dynamic(
            [conversation],
            conversation.scope == "workspace" and conversation.workspace_id == ^workspace_id and
              conversation.workspace_id in ^workspace_ids
          )
      end

    where(query, ^condition)
  end

  defp after_keyset(query, nil), do: query

  defp after_keyset(query, {updated_at, id}) do
    where(
      query,
      [conversation],
      conversation.updated_at < ^updated_at or
        (conversation.updated_at == ^updated_at and conversation.id < ^id)
    )
  end

  defp entries_for_batch(conversations, filters, cursor, remaining) do
    targets =
      Enum.reject(conversations, fn conversation ->
        filters.query == "" or filters.content == "title" or title_match?(conversation, filters)
      end)

    cond do
      targets == [] ->
        {:ok, empty_entry_scan()}

      remaining <= 0 ->
        {:ok, %{empty_entry_scan() | lookahead: first_candidate(targets, filters, cursor)}}

      true ->
        load_entry_scan(targets, filters, cursor, remaining)
    end
  end

  defp load_entry_scan(conversations, filters, cursor, remaining) do
    ids = Enum.map(conversations, & &1.id)

    candidates =
      ConversationEntry
      |> join(:inner, [entry], conversation in Conversation,
        on: conversation.id == entry.conversation_id
      )
      |> where([entry, _conversation], entry.conversation_id in ^ids)
      |> searchable_message_filter(filters.content)
      |> after_entry_cursor(cursor.pending)
      |> order_by(
        [entry, conversation],
        desc: conversation.updated_at,
        desc: conversation.id,
        asc: entry.sequence,
        asc: entry.entry_id
      )
      |> limit(^(remaining + 1))
      |> select([entry, _conversation], %{
        storage_id: entry.id,
        conversation_id: entry.conversation_id,
        sequence: entry.sequence,
        entry_id: entry.entry_id
      })
      |> Repo.all()

    checked = Enum.take(candidates, remaining)
    checked_ids = Enum.map(checked, & &1.storage_id)
    lookahead = Enum.at(candidates, remaining)

    rows =
      if checked_ids == [] do
        []
      else
        ConversationEntry
        |> join(:inner, [entry], conversation in Conversation,
          on: conversation.id == entry.conversation_id
        )
        |> where([entry, _conversation], entry.id in ^checked_ids)
        |> searchable_message_filter(filters.content)
        |> literal_content_filter(filters.query)
        |> order_by(
          [entry, conversation],
          desc: conversation.updated_at,
          desc: conversation.id,
          asc: entry.sequence,
          asc: entry.entry_id
        )
        |> select([entry, _conversation], %{
          storage_id: entry.id,
          conversation_id: entry.conversation_id,
          entry_id: entry.entry_id,
          sequence: entry.sequence,
          role: entry.role,
          content: entry.content
        })
        |> Repo.all()
      end

    projected = Enum.flat_map(rows, &project_searchable_entry(&1, filters.query))

    {:ok,
     %{
       checked: Enum.group_by(checked, & &1.conversation_id),
       matches: Enum.group_by(projected, & &1.conversation_id),
       lookahead: lookahead,
       checked_count: length(checked)
     }}
  end

  defp first_candidate(conversations, filters, cursor) do
    {:ok, scan} = load_entry_scan(conversations, filters, cursor, 0)
    scan.lookahead
  end

  defp empty_entry_scan do
    %{checked: %{}, matches: %{}, lookahead: nil, checked_count: 0}
  end

  defp after_entry_cursor(query, nil), do: query

  defp after_entry_cursor(query, %{conversation_id: conversation_id, entry_key: {sequence, id}}) do
    where(
      query,
      [entry, _conversation],
      entry.conversation_id != ^conversation_id or entry.sequence > ^sequence or
        (entry.sequence == ^sequence and entry.entry_id > ^id)
    )
  end

  defp searchable_message_filter(query, content) do
    kinds = if content == "all", do: ["user", "assistant"], else: [content]

    where(
      query,
      [entry, ...],
      entry.role in ^kinds and
        (is_nil(entry.status) or entry.status not in ["streaming", "running"]) and
        (is_nil(entry.message_type) or entry.message_type != "internal") and
        (is_nil(entry.content_type) or
           entry.content_type not in ["tool", "memory_reflection", "model_compaction"]) and
        fragment(
          "COALESCE(json_extract(?, '$.origin.kind'), '') != 'conversation'",
          entry.payload
        ) and
        (entry.role != "user" or
           fragment("COALESCE(json_extract(?, '$.channel'), '') != 'internal'", entry.payload)) and
        not (fragment("COALESCE(json_extract(?, '$.source'), '') = 'delegation'", entry.payload) and
               fragment("COALESCE(json_extract(?, '$.channel'), '') = 'internal'", entry.payload)) and
        not fragment("COALESCE(?, '') LIKE 'Background subagent report%'", entry.content) and
        not fragment(
          "COALESCE(?, '') LIKE 'Delegated report (requires parent review):%'",
          entry.content
        ) and
        ((entry.role == "user" and
            ((entry.content_type == "user_msg" and
                (is_nil(entry.message_type) or entry.message_type == "user") and
                (is_nil(entry.direction) or entry.direction == "inbound")) or
               (is_nil(entry.content_type) and is_nil(entry.message_type) and
                  is_nil(entry.direction)))) or
           (entry.role == "assistant" and
              (is_nil(entry.phase) or entry.phase in ["commentary", "final_answer", "final"]) and
              ((entry.content_type == "assistant_msg" and
                  (is_nil(entry.message_type) or entry.message_type == "assistant") and
                  (is_nil(entry.direction) or entry.direction == "outbound")) or
                 (is_nil(entry.content_type) and is_nil(entry.message_type) and
                    is_nil(entry.direction)))))
    )
  end

  defp literal_content_filter(query, ""), do: query

  defp literal_content_filter(query, value) do
    where(
      query,
      [entry, ...],
      fragment("instr(lower(COALESCE(?, '')), lower(?)) > 0", entry.content, ^value)
    )
  end

  defp project_searchable_entry(entry, query) do
    content = sanitize(entry.content || "")

    if literal_contains?(content, query) do
      [
        %{
          conversation_id: entry.conversation_id,
          entry_id: entry.entry_id,
          sequence: entry.sequence,
          source: entry.role,
          snippet: snippet(content, query)
        }
      ]
    else
      []
    end
  end

  defp project_result(conversation, message_matches, filters) do
    safe_title = conversation.title |> Kernel.||("") |> sanitize()

    title_match? = title_match?(conversation, filters)

    title = String.slice(safe_title, 0, 200)
    message_matches = Enum.take(message_matches, 1)

    if filters.query == "" or title_match? or message_matches != [] do
      %{
        conversation_id: conversation.id,
        title: title,
        scope: conversation.scope,
        workspace_id: conversation.workspace_id,
        archived: not is_nil(conversation.archived_at),
        updated_at: DateTime.to_iso8601(conversation.updated_at),
        title_match: title_match?,
        matches: message_matches
      }
    end
  end

  defp authorized_conversation(scope, id) do
    Conversation
    |> where(
      [conversation],
      conversation.id == ^id and conversation.status == "active" and
        conversation.visibility == "user"
    )
    |> scope_filter(scope, :all)
    |> Repo.one()
  end

  defp searchable_entry_exists?(conversation_id, entry_id) do
    ConversationEntry
    |> where(
      [entry],
      entry.conversation_id == ^conversation_id and entry.entry_id == ^entry_id
    )
    |> searchable_message_filter("all")
    |> Repo.exists?()
  end

  defp conversation_projection(conversation) do
    %{
      conversation_id: conversation.id,
      scope: conversation.scope,
      workspace_id: conversation.workspace_id,
      archived: not is_nil(conversation.archived_at)
    }
  end

  defp snippet(value, query) do
    folded = String.downcase(value)
    needle = String.downcase(query)

    start =
      case :binary.match(folded, needle) do
        {byte_offset, _length} -> max(codepoint_offset(value, byte_offset) - @snippet_radius, 0)
        :nomatch -> 0
      end

    prefix = if start > 0, do: "…", else: ""
    text = String.slice(value, start, @snippet_radius * 2)
    suffix = if start + String.length(text) < String.length(value), do: "…", else: ""
    prefix <> text <> suffix
  end

  defp codepoint_offset(value, folded_byte_offset) do
    value
    |> String.codepoints()
    |> Enum.reduce_while({0, 0}, fn codepoint, {index, bytes} ->
      next = bytes + byte_size(String.downcase(codepoint))
      if next <= folded_byte_offset, do: {:cont, {index + 1, next}}, else: {:halt, {index, bytes}}
    end)
    |> elem(0)
  end

  defp sanitize(value), do: Handbean.Log.Redactor.redact(value)
  defp literal_contains?(_value, ""), do: true

  defp literal_contains?(value, query) do
    String.contains?(String.downcase(value), String.downcase(query))
  end

  defp title_match?(conversation, filters) do
    filters.content in ["all", "title"] and
      literal_contains?(sanitize(conversation.title || ""), filters.query)
  end

  defp conversation_keyset(conversation), do: {conversation.updated_at, conversation.id}

  defp entry_key(nil), do: nil
  defp entry_key(entry), do: {entry.sequence, entry.entry_id}

  defp positive_budget(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp validate_keys(input) do
    if Enum.all?(Map.keys(input), &(&1 in ~w(query content range limit cursor))),
      do: :ok,
      else: {:error, :invalid_input}
  end

  defp content(input) do
    case Map.get(input, "content", "all") do
      value when value in @contents -> {:ok, value}
      _value -> {:error, :invalid_input}
    end
  end

  defp range(input, scope) do
    case Map.get(input, "range", "all") do
      "all" -> {:ok, :all}
      "free" when scope.free? -> {:ok, :free}
      "workspace:" <> workspace_id -> workspace_range(scope, workspace_id)
      _value -> {:error, :invalid_input}
    end
  end

  defp workspace_range(scope, workspace_id) do
    if MapSet.member?(scope.workspace_ids, workspace_id),
      do: {:ok, {:workspace, workspace_id}},
      else: {:error, :invalid_input}
  end

  defp text(input, key, default, max) do
    value = Map.get(input, key, default)

    if is_binary(value) and String.valid?(value) and byte_size(value) <= max * 4 and
         String.length(value) <= max,
       do: {:ok, value},
       else: {:error, :invalid_input}
  end

  defp integer(input, key, default, min, max) do
    value = Map.get(input, key, default)

    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: {:error, :invalid_input}
  end

  defp decode_cursor(cursor, _filters, _scope) when cursor in [nil, ""],
    do: {:ok, %{completed: nil, pending: nil}}

  defp decode_cursor(cursor, filters, scope)
       when is_binary(cursor) and byte_size(cursor) <= 2048 do
    binding = cursor_binding(filters, scope)

    case Handbean.EndpointAdapter.verify(@cursor_salt, cursor, max_age: 3600) do
      {:ok, {^binding, 2, completed, pending}} ->
        validate_cursor_state(completed, pending)

      _other ->
        {:error, :stale_or_invalid_cursor}
    end
  end

  defp decode_cursor(_cursor, _filters, _scope), do: {:error, :stale_or_invalid_cursor}

  defp encode_cursor(%{completed: completed, pending: pending}, filters, scope) do
    Handbean.EndpointAdapter.sign(
      @cursor_salt,
      {cursor_binding(filters, scope), 2, completed, pending}
    )
  end

  defp validate_cursor_state(completed, pending) do
    with :ok <- validate_conversation_key(completed),
         :ok <- validate_pending_cursor(pending) do
      {:ok, %{completed: completed, pending: pending}}
    else
      _error -> {:error, :stale_or_invalid_cursor}
    end
  end

  defp validate_conversation_key(nil), do: :ok

  defp validate_conversation_key({%DateTime{}, id}) when is_binary(id) and id != "", do: :ok
  defp validate_conversation_key(_value), do: :error

  defp validate_pending_cursor(nil), do: :ok

  defp validate_pending_cursor(%{
         conversation_id: id,
         selected_key: selected_key,
         entry_key: {sequence, entry_id}
       })
       when is_binary(id) and id != "" and is_integer(sequence) and is_binary(entry_id) and
              entry_id != "" do
    validate_conversation_key(selected_key)
  end

  defp validate_pending_cursor(_value), do: :error

  defp cursor_binding(filters, scope) do
    workspace_ids = scope.workspace_ids |> MapSet.to_list() |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({filters, workspace_ids, scope.free?}))
    |> Base.url_encode64(padding: false)
  end
end
