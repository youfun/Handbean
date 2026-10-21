defmodule Handbean.Attachments.History do
  @moduledoc """
  Rebuild provider messages from persisted attachment references.
  Missing or invalid images become explicit text, never silent text-only history.

  A rebuilt context always leads with a user message: after a compaction, a
  leading assistant entry (imported or injected history) is dropped in favor
  of the checkpoint summary, which is a user message.
  """

  alias Handbean.Agent.{CompactionCheckpoint, Compactor}
  alias Handbean.Agent.Message
  alias Handbean.Attachments
  alias Handbean.Attachments.Access

  @reasoning_replay_recent_tokens 20_000

  def to_messages(entry_or_entries, workspace_path, conversation_id \\ nil)

  @spec to_messages([map()], String.t() | nil, String.t() | nil) :: [Message.t()]
  def to_messages(entries, workspace_path, conversation_id) when is_list(entries) do
    case CompactionCheckpoint.projection(entries) do
      {:ok, projection} ->
        first = to_messages(projection.first_entry, workspace_path, conversation_id)

        summary = %Message{
          role: :user,
          content:
            "#{Compactor.summary_prefix()}\n#{String.trim(projection.checkpoint["summary"])}",
          id: projection.checkpoint["id"]
        }

        suffix =
          projection.suffix_entries
          |> Enum.flat_map(&to_messages(&1, workspace_path, conversation_id))
          |> retain_recent_reasoning(@reasoning_replay_recent_tokens)

        drop_leading_assistant(first) ++ [summary] ++ suffix

      :none ->
        entries
        |> Enum.flat_map(&to_messages(&1, workspace_path, conversation_id))
        |> retain_recent_reasoning(@reasoning_replay_recent_tokens)
    end
  end

  @spec to_messages(map(), String.t() | nil, String.t() | nil) :: [Message.t()]
  def to_messages(entry, workspace_path, conversation_id) when is_map(entry) do
    role = entry["role"]
    text = entry["content"]
    attachments = List.wrap(entry["attachments"])
    conversation_id = conversation_id || entry["conversation_id"]

    messages =
      cond do
        role == "tool" and attachments == [] ->
          restore_tool(entry, conversation_id)

        role == "user" and attachments != [] ->
          case rebuild_user(text, attachments, workspace_path, conversation_id, entry) do
            {:ok, content} -> [%Message{role: :user, content: content}]
            {:error, _reason} -> fallback_user(text, attachments)
          end

        role == "user" and is_binary(text) and text != "" ->
          [Message.user(text)]

        role == "assistant" and replayable_assistant?(entry) and is_binary(text) and text != "" ->
          [assistant_message(entry, text)]

        true ->
          []
      end

    stamp_entry_id(messages, entry["id"])
  end

  def to_messages(_, _, _), do: []

  # A rebuilt context must lead with a user message: providers reject an
  # assistant-first context, and a leading assistant entry (imported or
  # injected history) has no user turn of its own. The checkpoint summary
  # that follows is a user message, so dropping leading assistant messages
  # keeps the lead valid without losing the handoff.
  defp drop_leading_assistant(messages) do
    Enum.drop_while(messages, &(&1.role == :assistant))
  end

  defp retain_recent_reasoning(messages, token_budget) do
    {kept, _tokens} =
      messages
      |> Enum.reverse()
      |> Enum.map_reduce(0, fn message, tokens ->
        without_reasoning = drop_reasoning(message)
        next_tokens = tokens + Compactor.request_tokens([without_reasoning], nil)
        kept_message = if tokens < token_budget, do: message, else: without_reasoning
        {kept_message, next_tokens}
      end)

    Enum.reverse(kept)
  end

  defp stamp_entry_id(messages, id) when is_binary(id) and id != "" do
    Enum.map(messages, &%{&1 | id: id})
  end

  defp stamp_entry_id(messages, _id), do: messages

  defp drop_reasoning(%Message{content: blocks} = message) when is_list(blocks) do
    %{message | content: Enum.reject(blocks, &reasoning_block?/1)}
  end

  defp drop_reasoning(message), do: message

  defp reasoning_block?(%{"type" => "responses_reasoning"}), do: true
  defp reasoning_block?(%{type: "responses_reasoning"}), do: true
  defp reasoning_block?(_block), do: false

  defp restore_tool(entry, conversation_id) do
    images = Handbean.Tool.Images.project(entry["images"])
    images = Enum.filter(images, &String.starts_with?(&1.ref, "#{conversation_id}/"))
    id = entry["tool_use_id"]

    if is_binary(id) and is_binary(entry["tool_name"]) and
         entry["tool_status"] in ["done", "error"] do
      call = %{type: "tool_use", id: id, name: entry["tool_name"], input: entry["input"] || %{}}

      assistant =
        entry["content_blocks"]
        |> replay_blocks()
        |> Kernel.++([call])
        |> Message.assistant_blocks()

      result =
        Message.tool_result_block(
          id,
          entry["output"] || "[Historical tool observation; observe again before input]",
          entry["tool_status"] == "error"
        )
        |> Map.put(:images, images)

      [assistant, Message.tool_results([result])]
    else
      []
    end
  end

  # Failed or cancelled assistant text is a loop, not context. Replaying it
  # teaches the next turn to continue the same degenerate output.
  defp replayable_assistant?(entry) do
    entry["status"] not in ["error", "cancelled"]
  end

  defp replay_blocks(blocks) when is_list(blocks) do
    Enum.filter(blocks, fn
      %{"type" => "responses_reasoning", "item" => item} when is_map(item) ->
        reasoning_item?(item)

      %{type: "responses_reasoning", item: item} when is_map(item) ->
        reasoning_item?(item)

      _ ->
        false
    end)
  end

  defp replay_blocks(_), do: []

  defp reasoning_item?(%{"type" => "reasoning", "encrypted_content" => encrypted})
       when is_binary(encrypted) and encrypted != "",
       do: true

  defp reasoning_item?(%{type: "reasoning", encrypted_content: encrypted})
       when is_binary(encrypted) and encrypted != "",
       do: true

  defp reasoning_item?(_), do: false

  defp assistant_message(entry, text) do
    text_block =
      %{type: "text", text: text}
      |> maybe_put(:phase, entry["phase"])
      |> maybe_put(:id, entry["id"])

    case replay_blocks(entry["content_blocks"]) do
      [] ->
        if text_block[:phase] in ["commentary", "final_answer"],
          do: Message.assistant_blocks([text_block]),
          else: Message.assistant(text)

      blocks ->
        Message.assistant_blocks(blocks ++ [text_block])
    end
  end

  defp maybe_put(block, _key, value) when value in [nil, ""], do: block
  defp maybe_put(block, key, value), do: Map.put(block, key, value)

  defp rebuild_user(text, attachments, workspace_path, conversation_id, entry) do
    text_blocks =
      if is_binary(text) and String.trim(text) != "",
        do: [%{type: "text", text: text}],
        else: []

    blocks =
      Enum.reduce(attachments, text_blocks, fn att, acc ->
        acc ++ restore_attachment(att, workspace_path, conversation_id, entry)
      end)

    if blocks == [] do
      {:error, :empty}
    else
      {:ok, if(only_plain_text?(blocks), do: hd(blocks).text, else: blocks)}
    end
  end

  defp restore_attachment(att, workspace_path, conversation_id, entry) do
    mime = Handbean.Utils.SafeMap.get_any(att, "mime_type", :mime_type)
    name = Handbean.Utils.SafeMap.get_any(att, "filename", :filename) || "attachment"
    relative = Handbean.Utils.SafeMap.get_any(att, "relative_path", :relative_path)

    cond do
      not is_nil(Handbean.Utils.SafeMap.get_any(att, "storage_path", :storage_path)) ->
        [%{type: "text", text: "Image attachment rejected: absolute storage path (#{name})"}]

      Attachments.image?(to_string(mime)) ->
        case load_image(workspace_path, conversation_id, relative, mime, entry) do
          {:ok, data} ->
            [%{type: "image", mime_type: mime, data: data}]

          {:error, reason} ->
            [%{type: "text", text: "Image attachment missing (#{name}): #{inspect(reason)}"}]
        end

      Attachments.text?(to_string(mime)) ->
        [%{type: "text", text: "Attached text file #{name} at #{relative || name}."}]

      true ->
        [%{type: "text", text: "Attachment #{name} is not available in this history window."}]
    end
  end

  defp load_image(workspace_path, conversation_id, relative, mime, entry) do
    with {:ok, path} <- resolve_history_upload(workspace_path, conversation_id, relative, entry),
         :ok <- Access.verify_canonical(path, mime),
         {:ok, bin} <- Access.read_bounded(path, Attachments.max_image_bytes()) do
      {:ok, Base.encode64(bin)}
    end
  end

  defp resolve_history_upload(workspace_path, conversation_id, relative, _entry)
       when is_binary(workspace_path) and is_binary(conversation_id) and is_binary(relative) do
    Access.resolve_upload(workspace_path, conversation_id, relative)
  end

  defp resolve_history_upload(_workspace_path, conversation_id, relative, entry)
       when is_binary(conversation_id) and is_binary(relative) do
    if free_history?(entry) do
      Access.resolve_free_upload(conversation_id, Path.basename(relative))
    else
      {:error, :malformed_ref}
    end
  end

  defp resolve_history_upload(_, _, _, _), do: {:error, :malformed_ref}

  defp free_history?(entry) do
    entry["scope"] == "free" or get_in(entry, ["metadata", "scope"]) == "free"
  end

  defp only_plain_text?([%{type: "text", text: text}]) when is_binary(text), do: true
  defp only_plain_text?(_), do: false

  defp fallback_user(text, attachments) do
    names =
      Enum.map_join(attachments, ", ", fn attachment ->
        Handbean.Utils.SafeMap.get_any(attachment, ["filename", :filename]) || "attachment"
      end)

    notice = "Attachments could not be restored: #{names}"
    body = [text, notice] |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.join("\n")
    if body == "", do: [], else: [Message.user(body)]
  end
end
