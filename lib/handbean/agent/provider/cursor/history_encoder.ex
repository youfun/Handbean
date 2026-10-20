defmodule Handbean.Agent.Provider.Cursor.HistoryEncoder do
  @moduledoc """
  Encodes transcript history into Cursor's content-addressed conversation blobs.

  This module is deliberately stateless. The session remains the owner of the
  blob store and decides when the returned store becomes part of a live run.
  """

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Cursor.{Blobs, Proto}

  def encode(messages, system_prompt, blobs, uuid_fun \\ &Ecto.UUID.generate/0)
      when is_list(messages) and is_map(blobs) and is_function(uuid_fun, 0) do
    {blobs, root_ids} = encode_prompt(messages, system_prompt, blobs)
    {blobs, turn_ids} = encode_turns(messages, blobs, uuid_fun)
    {root_ids, turn_ids, blobs}
  end

  @doc false
  def text(content) when is_binary(content), do: content
  def text(content) when is_list(content), do: Message.text(%Message{content: content})
  def text(%{text: text}) when is_binary(text), do: text
  def text(%{content: content}), do: text(content)
  def text(_), do: ""

  defp encode_prompt(messages, system_prompt, blobs) do
    Enum.reduce(prompt_json(messages, system_prompt), {blobs, []}, fn json, {blobs, ids} ->
      {id, blobs} = Blobs.put(blobs, json)
      {blobs, ids ++ [id]}
    end)
  end

  defp prompt_json(messages, system_prompt) do
    system =
      if is_binary(system_prompt) and system_prompt != "" do
        [Handbean.JSON.encode!(%{"role" => "system", "content" => system_prompt})]
      else
        []
      end

    rest =
      Enum.flat_map(messages, fn
        %Message{role: :user, content: content} ->
          [
            Handbean.JSON.encode!(%{
              "role" => "user",
              "content" => [%{"type" => "text", "text" => text(content)}]
            })
          ]

        %Message{role: :assistant, content: content} ->
          [
            Handbean.JSON.encode!(%{
              "role" => "assistant",
              "content" => assistant_content_json(content)
            })
          ]

        %Message{role: :tool_result, content: content} ->
          Enum.map(List.wrap(content), fn block ->
            Handbean.JSON.encode!(%{
              "role" => "tool",
              "tool_use_id" => Handbean.Utils.SafeMap.get_any(block, :tool_use_id, "tool_use_id"),
              "content" => tool_result_text(block),
              "is_error" => Handbean.Utils.SafeMap.get_any(block, :is_error, "is_error") || false
            })
          end)

        _ ->
          []
      end)

    system ++ rest
  end

  defp assistant_content_json(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp assistant_content_json(blocks) when is_list(blocks) do
    Enum.map(blocks, fn
      %{type: "text", text: text} ->
        %{"type" => "text", "text" => text}

      %{"type" => "text", "text" => text} ->
        %{"type" => "text", "text" => text}

      %{type: "tool_use"} = block ->
        tool_use_json(block)

      %{"type" => "tool_use"} = block ->
        %{
          "type" => "tool_use",
          "id" => block["id"],
          "name" => block["name"],
          "input" => block["input"] || %{}
        }

      block ->
        %{"type" => "text", "text" => text(block)}
    end)
  end

  defp assistant_content_json(other), do: [%{"type" => "text", "text" => text(other)}]

  defp tool_use_json(block) do
    %{
      "type" => "tool_use",
      "id" => Handbean.Utils.SafeMap.get_any(block, :id, "id"),
      "name" => Handbean.Utils.SafeMap.get_any(block, :name, "name"),
      "input" => Handbean.Utils.SafeMap.get_any(block, :input, "input") || %{}
    }
  end

  defp encode_turns(messages, blobs, uuid_fun) do
    messages
    |> chunk_turns()
    |> Enum.reduce({blobs, []}, fn {user_msg, steps}, {blobs, ids} ->
      message_id = user_msg.id || uuid_fun.()

      {user_id, blobs} =
        Blobs.put(blobs, Proto.encode_user_message(text(user_msg.content), message_id))

      {blobs, step_ids} =
        Enum.reduce(steps, {blobs, []}, fn step, {blobs, acc} ->
          {id, blobs} = Blobs.put(blobs, encode_turn_step(step))
          {blobs, acc ++ [id]}
        end)

      {turn_id, blobs} = Blobs.put(blobs, Proto.encode_turn(user_id, step_ids))
      {blobs, ids ++ [turn_id]}
    end)
  end

  defp encode_turn_step({:assistant, text}), do: Proto.encode_assistant_step(text)

  defp encode_turn_step({:mcp_call, id, name, input, result}) do
    Proto.encode_tool_call_step(id, name, stringify_tool_input(input), result)
  end

  defp assistant_steps(%Message{content: content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: "text", text: text} -> [{:assistant, text}]
      %{"type" => "text", "text" => text} -> [{:assistant, text}]
      %{type: "tool_use"} = block -> [tool_use_step(block)]
      %{"type" => "tool_use"} = block -> [tool_use_step(block)]
      _ -> []
    end)
  end

  defp assistant_steps(%Message{content: content}) when is_binary(content),
    do: [{:assistant, content}]

  defp assistant_steps(_), do: []

  defp tool_use_step(block) do
    id = Handbean.Utils.SafeMap.get_any(block, :id, "id")
    name = Handbean.Utils.SafeMap.get_any(block, :name, "name")
    input = Handbean.Utils.SafeMap.get_any(block, :input, "input") || %{}
    {:pending_mcp, id, name, input}
  end

  defp chunk_turns(messages) do
    messages
    |> Enum.reduce({[], nil, []}, &chunk_turn_message/2)
    |> finish_chunk()
  end

  defp chunk_turn_message(%Message{role: :user} = msg, {acc, nil, steps}) do
    {acc, msg, steps}
  end

  defp chunk_turn_message(%Message{role: :user} = msg, {acc, user, steps}) do
    {acc ++ [{user, Enum.reverse(finalize_mcp_steps(steps))}], msg, []}
  end

  defp chunk_turn_message(%Message{role: :assistant} = msg, {acc, user, steps})
       when not is_nil(user) do
    {acc, user, Enum.reverse(assistant_steps(msg)) ++ steps}
  end

  defp chunk_turn_message(%Message{role: :tool_result, content: content}, {acc, user, steps})
       when not is_nil(user) do
    steps =
      Enum.reduce(List.wrap(content), steps, fn block, steps ->
        attach_tool_result(steps, block)
      end)

    {acc, user, steps}
  end

  defp chunk_turn_message(_, acc), do: acc

  defp finish_chunk({acc, nil, _}), do: acc

  defp finish_chunk({acc, user, steps}) do
    acc ++ [{user, Enum.reverse(finalize_mcp_steps(steps))}]
  end

  defp attach_tool_result(steps, block) do
    id = Handbean.Utils.SafeMap.get_any(block, :tool_use_id, "tool_use_id")
    result = mcp_result_from_block(block)

    Enum.map(steps, fn
      {:pending_mcp, ^id, name, input} -> {:mcp_call, id, name, input, result}
      other -> other
    end)
  end

  defp finalize_mcp_steps(steps) do
    Enum.map(steps, fn
      {:pending_mcp, id, name, input} -> {:mcp_call, id, name, input, nil}
      other -> other
    end)
  end

  defp mcp_result_from_block(block) do
    result = tool_result_text(block)
    is_error? = Handbean.Utils.SafeMap.get_any(block, :is_error, "is_error") || false
    {:success, result, is_error?}
  end

  defp tool_result_text(content) when is_binary(content), do: content

  defp tool_result_text(blocks) when is_list(blocks),
    do: Enum.map_join(blocks, "\n", &tool_result_text/1)

  defp tool_result_text(%{content: content}), do: text(content)
  defp tool_result_text(%{"content" => content}), do: text(content)
  defp tool_result_text(other), do: text(other)

  defp stringify_tool_input(input) when is_map(input) do
    Handbean.Agent.Provider.stringify_keys(input)
  end
end
