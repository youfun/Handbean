defmodule Handbean.Agent.SecretMasking.Transformer do
  @moduledoc false

  alias Handbean.Agent.Message

  @opaque_block_types ~w(redacted_thinking responses_reasoning codex_reasoning)
  @media_block_types ~w(image audio video document)

  @type text_mapper :: (String.t() -> String.t())

  @spec regular_texts([Message.t()], [map()], map()) ::
          {:ok, [String.t()]} | {:error, term()}
  def regular_texts(messages, tools, config)
      when is_list(messages) and is_list(tools) and is_map(config) do
    with {:ok, message_texts} <- collect_messages(messages),
         {:ok, tool_texts} <- collect_tools(tools) do
      system =
        case Map.get(config, :system_prompt) do
          text when is_binary(text) -> [text]
          _other -> []
        end

      {:ok, system ++ message_texts ++ tool_texts}
    end
  end

  @spec mask_request([Message.t()], [map()], map(), text_mapper(), text_mapper()) ::
          {:ok, {[Message.t()], [map()], map()}} | {:error, term()}
  def mask_request(messages, tools, config, regular, signed)
      when is_function(regular, 1) and is_function(signed, 1) do
    with {:ok, messages} <- map_messages(messages, regular, signed),
         {:ok, tools} <- map_tools(tools, regular) do
      config =
        case Map.get(config, :system_prompt) do
          text when is_binary(text) -> Map.put(config, :system_prompt, regular.(text))
          _other -> config
        end

      {:ok, {messages, tools, config}}
    end
  end

  @spec restore_response(map(), map()) :: {:ok, map()} | {:error, term()}
  def restore_response(%{messages: messages} = response, restore_map) when is_list(messages) do
    restore = &Handbean.Agent.SecretMasking.restore(&1, restore_map)

    with {:ok, messages} <- map_messages(messages, restore, restore) do
      {:ok, %{response | messages: messages}}
    end
  end

  def restore_response(response, _restore_map) when is_map(response), do: {:ok, response}

  defp collect_messages(messages) do
    collect_many(messages, fn
      %Message{} = message -> collect_message(message)
      _other -> {:error, :invalid_provider_message}
    end)
  end

  defp collect_message(%Message{} = message) do
    with {:ok, content} <- collect_content(message.content),
         {:ok, tool_calls} <- collect_tool_calls(message.tool_calls) do
      {:ok, content ++ tool_calls}
    end
  end

  defp collect_content(nil), do: {:ok, []}
  defp collect_content(text) when is_binary(text), do: {:ok, [text]}
  defp collect_content(blocks) when is_list(blocks), do: collect_many(blocks, &collect_block/1)
  defp collect_content(block) when is_map(block), do: collect_block(block)
  defp collect_content(_other), do: {:error, :invalid_message_content}

  defp collect_block(block) when is_map(block) do
    case block_type(block) do
      "text" ->
        binary_field_text(block, :text)

      "thinking" ->
        if signed_thinking?(block), do: {:ok, []}, else: binary_field_text(block, :thinking)

      type when type in @opaque_block_types ->
        {:ok, []}

      type when type in @media_block_types ->
        {:ok, []}

      type when type in ["tool_use", "server_tool_use"] ->
        collect_semantic(field(block, :input))

      type when type in ["tool_result", "server_tool_result"] ->
        collect_result_content(field(block, :content))

      type ->
        {:error, {:unknown_content_block, type}}
    end
  end

  defp collect_block(_other), do: {:error, :invalid_content_block}

  defp collect_result_content(content) when is_list(content) do
    if Enum.all?(content, &is_map/1),
      do: collect_many(content, &collect_block/1),
      else: collect_semantic(content)
  end

  defp collect_result_content(content), do: collect_semantic(content)

  defp collect_semantic(value) when is_binary(value), do: {:ok, [value]}
  defp collect_semantic(nil), do: {:ok, []}

  defp collect_semantic(value) when is_list(value),
    do: collect_many(value, &collect_semantic/1)

  defp collect_semantic(value) when is_map(value),
    do: value |> Map.values() |> collect_many(&collect_semantic/1)

  defp collect_semantic(_value), do: {:ok, []}

  defp collect_tool_calls(nil), do: {:ok, []}

  defp collect_tool_calls(calls) when is_list(calls) do
    collect_many(calls, fn
      call when is_map(call) -> collect_semantic(field(call, :input))
      _other -> {:error, :invalid_tool_call}
    end)
  end

  defp collect_tool_calls(_other), do: {:error, :invalid_tool_calls}

  defp collect_tools(tools) do
    collect_many(tools, fn
      tool when is_map(tool) ->
        description =
          case field(tool, :description) do
            text when is_binary(text) -> [text]
            _other -> []
          end

        {:ok, description ++ schema_descriptions(field(tool, :input_schema))}

      _other ->
        {:error, :invalid_tool_definition}
    end)
  end

  defp schema_descriptions(value) when is_list(value),
    do: Enum.flat_map(value, &schema_descriptions/1)

  defp schema_descriptions(value) when is_map(value) do
    Enum.flat_map(value, fn {key, child} ->
      own = if key_name(key) == "description" and is_binary(child), do: [child], else: []
      own ++ schema_descriptions(child)
    end)
  end

  defp schema_descriptions(_value), do: []

  defp map_messages(messages, regular, signed) do
    map_many(messages, fn
      %Message{} = message -> map_message(message, regular, signed)
      _other -> {:error, :invalid_provider_message}
    end)
  end

  defp map_message(%Message{} = message, regular, signed) do
    with {:ok, content} <- map_content(message.content, regular, signed),
         {:ok, tool_calls} <- map_tool_calls(message.tool_calls, regular) do
      {:ok, %{message | content: content, tool_calls: tool_calls}}
    end
  end

  defp map_content(nil, _regular, _signed), do: {:ok, nil}
  defp map_content(text, regular, _signed) when is_binary(text), do: {:ok, regular.(text)}

  defp map_content(blocks, regular, signed) when is_list(blocks),
    do: map_many(blocks, &map_block(&1, regular, signed))

  defp map_content(block, regular, signed) when is_map(block),
    do: map_block(block, regular, signed)

  defp map_content(_other, _regular, _signed), do: {:error, :invalid_message_content}

  defp map_block(block, regular, signed) when is_map(block) do
    case block_type(block) do
      "text" ->
        map_binary_field(block, :text, regular)

      "thinking" ->
        map_binary_field(block, :thinking, if(signed_thinking?(block), do: signed, else: regular))

      type when type in @opaque_block_types ->
        {:ok, block}

      type when type in @media_block_types ->
        {:ok, block}

      type when type in ["tool_use", "server_tool_use"] ->
        map_semantic_field(block, :input, regular)

      type when type in ["tool_result", "server_tool_result"] ->
        map_result_content(block, regular, signed)

      type ->
        {:error, {:unknown_content_block, type}}
    end
  end

  defp map_block(_other, _regular, _signed), do: {:error, :invalid_content_block}

  defp map_result_content(block, regular, signed) do
    content = field(block, :content)

    result =
      if is_list(content) and Enum.all?(content, &is_map/1) do
        map_many(content, &map_block(&1, regular, signed))
      else
        {:ok, map_semantic(content, regular)}
      end

    with {:ok, content} <- result do
      {:ok, put_field(block, :content, content)}
    end
  end

  defp map_semantic_field(block, key, regular) do
    {:ok, put_field(block, key, map_semantic(field(block, key), regular))}
  end

  defp map_semantic(value, regular) when is_binary(value), do: regular.(value)

  defp map_semantic(value, regular) when is_list(value),
    do: Enum.map(value, &map_semantic(&1, regular))

  defp map_semantic(value, regular) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, map_semantic(child, regular)} end)

  defp map_semantic(value, _regular), do: value

  defp map_tool_calls(nil, _regular), do: {:ok, nil}

  defp map_tool_calls(calls, regular) when is_list(calls) do
    map_many(calls, fn
      call when is_map(call) ->
        {:ok, put_field(call, :input, map_semantic(field(call, :input), regular))}

      _other ->
        {:error, :invalid_tool_call}
    end)
  end

  defp map_tool_calls(_other, _regular), do: {:error, :invalid_tool_calls}

  defp map_tools(tools, regular) do
    map_many(tools, fn
      tool when is_map(tool) ->
        tool =
          case field(tool, :description) do
            text when is_binary(text) -> put_field(tool, :description, regular.(text))
            _other -> tool
          end

        schema = map_schema_descriptions(field(tool, :input_schema), regular)
        {:ok, put_field(tool, :input_schema, schema)}

      _other ->
        {:error, :invalid_tool_definition}
    end)
  end

  defp map_schema_descriptions(value, regular) when is_list(value),
    do: Enum.map(value, &map_schema_descriptions(&1, regular))

  defp map_schema_descriptions(value, regular) when is_map(value) do
    Map.new(value, fn {key, child} ->
      mapped =
        if key_name(key) == "description" and is_binary(child),
          do: regular.(child),
          else: map_schema_descriptions(child, regular)

      {key, mapped}
    end)
  end

  defp map_schema_descriptions(value, _regular), do: value

  defp binary_field_text(block, key) do
    case field(block, key) do
      text when is_binary(text) -> {:ok, [text]}
      _other -> {:error, {:invalid_content_block_field, block_type(block), key}}
    end
  end

  defp map_binary_field(block, key, mapper) do
    case field(block, key) do
      text when is_binary(text) -> {:ok, put_field(block, key, mapper.(text))}
      _other -> {:error, {:invalid_content_block_field, block_type(block), key}}
    end
  end

  defp signed_thinking?(block) do
    case field(block, :signature) do
      signature when is_binary(signature) and signature != "" -> true
      _other -> false
    end
  end

  defp block_type(block), do: field(block, :type)

  defp field(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp put_field(map, key, value) do
    if Map.has_key?(map, key),
      do: Map.put(map, key, value),
      else: Map.put(map, Atom.to_string(key), value)
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(_key), do: ""

  defp collect_many(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, collected} -> {:cont, {:ok, acc ++ collected}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp map_many(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end
  end
end
