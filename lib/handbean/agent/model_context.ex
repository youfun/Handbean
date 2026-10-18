defmodule Handbean.Agent.ModelContext do
  @moduledoc """
  Model-facing copy of one run.

  `State.messages` and the transcript stay intact. Provider calls see this
  copy. The original task stays. The model reads the copy with `read_context`
  and replaces one exact span with `edit_context`.
  """

  alias Handbean.Agent.{Message, State}
  alias Handbean.Agent.Provider.Continuation
  alias Handbean.Utils.SafeMap

  @max_new_bytes 8_000
  @view_omitted "[Earlier context view omitted after edit.]"

  @doc """
  Tells the model it owns this run's context and when to edit it.
  """
  @spec prompt_section() :: String.t()
  def prompt_section do
    """

    ## Context

    You own the context sent on later requests in this run. The transcript is not rewritten.

    Every tool result ends with a `[context: ~N of M tokens]` marker: the request size
    estimated when that result was produced. Keep later requests below M.

    After a long tool result is no longer needed verbatim, call `read_context`, then `edit_context`.
    Copy `old_text` from the body under a `[[ctx:N]]` line. Do not include that fence line.
    `new_text` replaces that one span. Keep the plan, paths, and facts; pass an empty `new_text` to delete the span.
    The original task, this system prompt, and the tool schemas stay.
    Do this while you still know what to keep, before the context grows large.
    """
  end

  @spec visible(State.t()) :: [Message.t()]
  def visible(%State{model_context: context, context_base_count: base, messages: messages})
      when is_list(context) and is_integer(base) and base >= 0 do
    context ++ Enum.drop(messages, base)
  end

  def visible(%State{messages: messages}), do: messages

  @spec install(State.t(), [Message.t()]) :: State.t()
  def install(%State{} = state, compacted) when is_list(compacted) do
    if compacted == visible(state) do
      state
    else
      generation = (state.context_generation || 0) + 1

      %{
        state
        | model_context: compacted,
          context_base_count: length(state.messages),
          usage_anchor: nil,
          context_generation: generation,
          provider_state: Continuation.fork(state, generation)
      }
    end
  end

  @doc """
  Records the full provider input for the next compaction check.

  `total_input_tokens` wins. Anthropic's `input_tokens` omits cache reads and
  cache writes, so a cache hit can look small while the window is full.
  Without a total, those three counts are added. OpenAI already reports an
  inclusive `total_input_tokens`, so the cache fields are not added again.
  """
  @spec note_anchor(State.t(), map() | nil, non_neg_integer()) :: State.t()
  def note_anchor(%State{} = state, usage, sent_count)
      when is_map(usage) and is_integer(sent_count) and sent_count >= 0 do
    case measured_input(usage) do
      input when input > 0 ->
        %{state | usage_anchor: %{input_tokens: input, sent_count: sent_count}}

      _ ->
        state
    end
  end

  def note_anchor(%State{} = state, _usage, _sent_count), do: state

  defp measured_input(usage) do
    total = usage_count(usage, :total_input_tokens, "total_input_tokens")

    if total > 0 do
      total
    else
      usage_count(usage, :input_tokens, "input_tokens") +
        usage_count(usage, :cache_read_input_tokens, "cache_read_input_tokens") +
        usage_count(usage, :cache_creation_input_tokens, "cache_creation_input_tokens")
    end
  end

  defp usage_count(usage, atom_key, string_key) do
    case SafeMap.get_any(usage, atom_key, string_key) do
      count when is_integer(count) and count > 0 -> count
      _ -> 0
    end
  end

  @doc """
  Renders the model-facing messages. Fence lines are labels, not part of `old_text`.
  """
  @spec render([Message.t()]) :: String.t()
  def render(messages) when is_list(messages) and messages != [] do
    messages
    |> Enum.with_index()
    |> Enum.map_join("\n\n", fn {msg, idx} ->
      tag = if idx == 0, do: "#{role_name(msg)} frozen", else: role_name(msg)
      "[[ctx:#{idx} #{tag}]]\n#{render_body(msg)}"
    end)
  end

  def render(_messages), do: "The context for this run is empty."

  @doc """
  Replaces one exact `old_text` in the editable tail.

  The first message stays. A `read_context` result block is not an editable
  source; sibling results in the same message still are. After a successful
  edit, that view is collapsed and the edit call no longer carries `old_text`.
  """
  @spec replace([Message.t()], term(), term()) :: {:ok, [Message.t()]} | {:error, String.t()}
  def replace(messages, old, new) when is_list(messages) do
    with :ok <- validate(old, new) do
      apply_replace(messages, old, new)
    end
  end

  def replace(_messages, _old, _new), do: {:error, "old_text is required"}

  defp validate(old, new) do
    cond do
      not is_binary(old) or old == "" ->
        {:error, "old_text is required"}

      not is_binary(new) ->
        {:error, "new_text is required"}

      byte_size(new) > @max_new_bytes ->
        {:error, "new_text must be at most 8000 bytes"}

      true ->
        :ok
    end
  end

  defp apply_replace(messages, old, new) do
    ids = view_ids(messages)
    frozen_hits = messages |> List.first() |> occurrence_count(old, MapSet.new())

    editable_hits =
      messages
      |> Enum.drop(1)
      |> Enum.reduce(0, fn msg, acc -> acc + occurrence_count(msg, old, ids) end)

    cond do
      editable_hits == 1 ->
        revised =
          messages
          |> rewrite(old, new, ids)
          |> collapse_views(ids)
          |> scrub_edits()

        {:ok, revised}

      editable_hits > 1 ->
        {:error,
         "old_text matched more than once. Include more surrounding text so it matches once."}

      frozen_hits > 0 ->
        {:error, "The original task cannot be edited."}

      true ->
        {:error,
         "old_text was not found in the editable context. Call read_context and copy the exact text."}
    end
  end

  defp rewrite(messages, old, new, ids) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn
      {msg, 0} -> msg
      {msg, _idx} -> replace_message(msg, old, new, ids)
    end)
  end

  defp replace_message(%Message{content: text} = msg, old, new, _ids) when is_binary(text) do
    %{msg | content: replace_once(text, old, new)}
  end

  defp replace_message(%Message{content: block} = msg, old, new, ids) when is_map(block) do
    %{msg | content: replace_editable_block(block, old, new, ids)}
  end

  defp replace_message(%Message{content: blocks} = msg, old, new, ids) when is_list(blocks) do
    %{msg | content: Enum.map(blocks, &replace_editable_block(&1, old, new, ids))}
  end

  defp replace_message(msg, _old, _new, _ids), do: msg

  defp replace_editable_block(block, old, new, ids) when is_map(block) do
    if view_block?(block, ids), do: block, else: replace_block(block, old, new)
  end

  defp replace_editable_block(other, _old, _new, _ids), do: other

  defp replace_block(block, old, new) when is_map(block) do
    case text_field(block) do
      {key, text} ->
        if String.contains?(text, old) do
          Map.put(block, key, replace_once(text, old, new))
        else
          block
        end

      nil ->
        block
    end
  end

  defp replace_once(text, old, new) do
    case String.split(text, old, parts: 2) do
      [head, tail] -> head <> new <> tail
      _ -> text
    end
  end

  defp collapse_views(messages, ids) do
    Enum.map(messages, fn msg ->
      if view_message?(msg, ids), do: collapse_message(msg, ids), else: msg
    end)
  end

  defp collapse_message(%Message{content: block} = msg, ids) when is_map(block) do
    %{msg | content: collapse_block(block, ids)}
  end

  defp collapse_message(%Message{content: blocks} = msg, ids) when is_list(blocks) do
    %{msg | content: Enum.map(blocks, &collapse_block(&1, ids))}
  end

  defp collapse_message(msg, _ids), do: msg

  defp collapse_block(block, ids) when is_map(block) do
    id = SafeMap.get_any(block, :tool_use_id, "tool_use_id")

    if is_binary(id) and MapSet.member?(ids, id) do
      case text_field(block) do
        {key, _text} -> Map.put(block, key, @view_omitted)
        nil -> block
      end
    else
      block
    end
  end

  defp collapse_block(other, _ids), do: other

  defp scrub_edits(messages) do
    Enum.map(messages, fn
      %Message{role: :assistant, content: blocks} = msg when is_list(blocks) ->
        %{msg | content: Enum.map(blocks, &scrub_block/1)}

      msg ->
        msg
    end)
  end

  defp scrub_block(block) when is_map(block) do
    type = SafeMap.get_any(block, :type, "type")
    name = SafeMap.get_any(block, :name, "name")

    if type == "tool_use" and name == "edit_context" do
      input = SafeMap.get_any(block, :input, "input") || %{}
      put_field(block, :input, "input", scrub_input(input))
    else
      block
    end
  end

  defp scrub_block(other), do: other

  defp scrub_input(input) when is_map(input) do
    input
    |> put_if_present("old_text", "[applied]")
    |> put_if_present(:old_text, "[applied]")
  end

  defp scrub_input(other), do: other

  defp put_if_present(map, key, value) do
    if Map.has_key?(map, key), do: Map.put(map, key, value), else: map
  end

  defp put_field(block, atom_key, string_key, value) do
    cond do
      Map.has_key?(block, atom_key) -> Map.put(block, atom_key, value)
      Map.has_key?(block, string_key) -> Map.put(block, string_key, value)
      true -> Map.put(block, atom_key, value)
    end
  end

  defp view_ids(messages) do
    messages
    |> Enum.flat_map(&view_call_ids/1)
    |> MapSet.new()
  end

  defp view_call_ids(%Message{role: :assistant, content: blocks}) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      block when is_map(block) ->
        type = SafeMap.get_any(block, :type, "type")
        name = SafeMap.get_any(block, :name, "name")
        id = SafeMap.get_any(block, :id, "id")

        if type == "tool_use" and name == "read_context" and is_binary(id) do
          [id]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp view_call_ids(_message), do: []

  defp view_message?(msg, ids) do
    Enum.any?(content_blocks(msg), &view_block?(&1, ids))
  end

  defp view_block?(block, ids) when is_map(block) do
    id = SafeMap.get_any(block, :tool_use_id, "tool_use_id")
    is_binary(id) and MapSet.member?(ids, id)
  end

  defp view_block?(_block, _ids), do: false

  defp occurrence_count(%Message{} = msg, old, ids) do
    msg
    |> text_values(ids)
    |> Enum.reduce(0, fn text, acc -> acc + count_in(text, old) end)
  end

  defp occurrence_count(_msg, _old, _ids), do: 0

  defp count_in(text, old) when is_binary(text) and is_binary(old) and old != "" do
    text |> String.split(old) |> length() |> Kernel.-(1)
  end

  defp count_in(_text, _old), do: 0

  defp text_values(%Message{content: text}, _ids) when is_binary(text), do: [text]

  defp text_values(%Message{content: block}, ids) when is_map(block) do
    if view_block?(block, ids), do: [], else: field_text(block)
  end

  defp text_values(%Message{content: blocks}, ids) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      block when is_map(block) ->
        if view_block?(block, ids), do: [], else: field_text(block)

      _ ->
        []
    end)
  end

  defp text_values(_msg, _ids), do: []

  defp field_text(block) do
    case text_field(block) do
      {_key, text} -> [text]
      nil -> []
    end
  end

  defp text_field(block) when is_map(block) do
    Enum.find_value([:content, "content", :text, "text"], fn key ->
      case Map.get(block, key) do
        text when is_binary(text) -> {key, text}
        _ -> nil
      end
    end)
  end

  defp content_blocks(%Message{content: block}) when is_map(block), do: [block]

  defp content_blocks(%Message{content: blocks}) when is_list(blocks),
    do: Enum.filter(blocks, &is_map/1)

  defp content_blocks(_msg), do: []

  defp role_name(%Message{role: role}) when is_atom(role), do: Atom.to_string(role)
  defp role_name(_msg), do: "message"

  defp render_body(%Message{content: text}) when is_binary(text), do: text

  defp render_body(%Message{content: blocks}) when is_list(blocks) do
    Enum.map_join(blocks, "\n", &render_block/1)
  end

  defp render_body(%Message{content: block}) when is_map(block), do: render_block(block)
  defp render_body(_msg), do: ""

  defp render_block(block) when is_map(block) do
    type = SafeMap.get_any(block, :type, "type")
    name = SafeMap.get_any(block, :name, "name")

    cond do
      type == "tool_use" and is_binary(name) ->
        "tool_use #{name}"

      true ->
        case text_field(block) do
          {_key, text} -> text
          nil -> ""
        end
    end
  end

  defp render_block(_block), do: ""
end
