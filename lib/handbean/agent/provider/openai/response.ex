defmodule Handbean.Agent.Provider.OpenAI.Response do
  @moduledoc false

  alias Handbean.Agent.Message

  require Logger

  @spec parse(binary() | map()) ::
          {:ok, Handbean.Agent.Provider.completion_response()} | {:error, String.t()}
  def parse(body) when is_binary(body) do
    case Handbean.Agent.Provider.decode_body(body) do
      {:ok, decoded} -> parse(decoded)
      {:error, _} = err -> err
    end
  end

  def parse(%{"error" => error}) when not is_nil(error) do
    {:error, format_error_payload(error)}
  end

  def parse(%{"status" => status}) when status not in [nil, "completed"] do
    {:error, "OpenAI response did not complete successfully"}
  end

  def parse(%{"output" => output} = response) when is_list(output) do
    usage = response["usage"] || %{}
    provider_state = provider_state_from_response(response)

    case parse_output_to_blocks(output) do
      {:ok, content_blocks} ->
        content_blocks = fallback_response_text_blocks(response, content_blocks)
        stop_reason = parse_stop_reason(content_blocks)

        Logger.debug(
          "[OpenAI] parsed response stop_reason=#{stop_reason} blocks=#{length(content_blocks)} " <>
            "text_bytes=#{byte_size(blocks_text(content_blocks))}"
        )

        message = %Message{role: :assistant, content: content_blocks}

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [message],
           usage: Handbean.Agent.Provider.openai_usage(usage),
           provider_state: provider_state,
           response_metadata: response_metadata_from_response(response)
         }}

      {:error, _} = error ->
        error
    end
  end

  def parse(%{"output_text" => text} = response) when is_binary(text) do
    usage = response["usage"] || %{}
    provider_state = provider_state_from_response(response)

    content_blocks =
      case text do
        "" -> []
        _ -> [%{type: "text", text: text}]
      end

    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [%Message{role: :assistant, content: content_blocks}],
       usage: Handbean.Agent.Provider.openai_usage(usage),
       provider_state: provider_state,
       response_metadata: response_metadata_from_response(response)
     }}
  end

  def parse(_response) do
    {:error, "Unexpected OpenAI response payload"}
  end

  @doc false
  def parse_output_item(%{"type" => "message", "role" => "assistant", "content" => content})
      when is_list(content) do
    if Enum.any?(content, &malformed_assistant_part?/1),
      do: {:error, "Malformed OpenAI assistant content"},
      else: {:ok, parse_assistant_content(content)}
  end

  def parse_output_item(%{"type" => "message", "role" => "assistant", "content" => text})
      when is_binary(text) do
    blocks =
      case text do
        "" -> []
        _ -> [%{type: "text", text: text}]
      end

    {:ok, blocks}
  end

  def parse_output_item(%{"type" => "function_call", "name" => name} = call)
      when is_binary(name) and name != "" do
    id = call["call_id"] || call["id"]

    if is_binary(id) and id != "" and String.trim(name) != "" do
      with {:ok, input} <- decode_function_call_arguments(call) do
        {:ok, [%{type: "tool_use", id: id, name: name, input: input}]}
      end
    else
      {:error, "Malformed OpenAI function_call"}
    end
  end

  def parse_output_item(%{"type" => "reasoning", "encrypted_content" => encrypted} = item)
      when is_binary(encrypted) and encrypted != "" do
    {:ok,
     [
       %{
         type: "responses_reasoning",
         item: Map.take(item, ["type", "id", "summary", "encrypted_content", "status"])
       }
     ]}
  end

  def parse_output_item(%{"type" => type}) when type in ["function_call", "message"],
    do: {:error, "Malformed OpenAI #{type}"}

  def parse_output_item(_item), do: {:ok, []}

  @doc false
  def text_fallback(response) do
    Enum.find_value(["output_text", "text", "message"], fn key ->
      case Map.get(response, key) do
        text when is_binary(text) and text != "" -> text
        _other -> nil
      end
    end)
  end

  @doc false
  def format_error_payload(error) when is_map(error) do
    type = Map.get(error, "type") || Map.get(error, "code") || "error"
    message = Map.get(error, "message") || "Provider request failed"
    "#{type}: #{message}"
  end

  def format_error_payload(error) when is_binary(error), do: error
  def format_error_payload(_error), do: "provider_error: Provider request failed"

  defp parse_output_to_blocks(output) do
    result =
      Enum.reduce_while(output, {:ok, []}, fn item, {:ok, acc} ->
        case parse_output_item(item) do
          {:ok, blocks} -> {:cont, {:ok, [blocks | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, nested} -> {:ok, nested |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp fallback_response_text_blocks(response, []) do
    response
    |> text_fallback()
    |> case do
      nil -> []
      text -> [%{type: "text", text: text}]
    end
  end

  defp fallback_response_text_blocks(_response, content_blocks), do: content_blocks

  defp malformed_assistant_part?(%{"type" => type} = part)
       when type in ["text", "output_text"], do: not is_binary(part["text"])

  defp malformed_assistant_part?(%{"type" => "refusal"} = part),
    do: not is_binary(part["refusal"] || part["text"])

  defp malformed_assistant_part?(part), do: not is_map(part)

  defp parse_assistant_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} = item when is_binary(text) and text != "" ->
        [%{type: "text", text: text} |> maybe_put_annotations(item["annotations"])]

      %{"type" => "text", "text" => text} = item when is_binary(text) and text != "" ->
        [%{type: "text", text: text} |> maybe_put_annotations(item["annotations"])]

      %{"text" => text} = item when is_binary(text) and text != "" ->
        [%{type: "text", text: text} |> maybe_put_annotations(item["annotations"])]

      %{"type" => "refusal", "refusal" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

      %{"type" => "refusal", "text" => text} when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

      _ ->
        []
    end)
  end

  defp parse_stop_reason(content_blocks) do
    if Enum.any?(content_blocks, &(&1.type == "tool_use")), do: :tool_use, else: :end_turn
  end

  defp decode_function_call_arguments(call) do
    case call["arguments"] do
      encoded when is_binary(encoded) ->
        case Handbean.JSON.decode(encoded) do
          {:ok, input} when is_map(input) -> {:ok, input}
          _ -> {:error, "Invalid JSON in tool call arguments: expected an object"}
        end

      decoded when is_map(decoded) ->
        {:ok, decoded}

      _other ->
        {:error, "Invalid tool call arguments payload: expected an object"}
    end
  end

  defp provider_state_from_response(%{"id" => id}) when is_binary(id) and id != "" do
    %{response_id: id}
  end

  defp provider_state_from_response(_response), do: %{}

  defp response_metadata_from_response(response) do
    %{}
    |> maybe_put_response_metadata(:citations, Map.get(response, "citations"))
    |> maybe_put_response_metadata(
      :server_side_tool_usage,
      Map.get(response, "server_side_tool_usage")
    )
  end

  defp maybe_put_response_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_response_metadata(metadata, _key, value) when value == [], do: metadata
  defp maybe_put_response_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_put_annotations(block, annotations)
       when is_list(annotations) and annotations != [] do
    Map.put(block, :annotations, annotations)
  end

  defp maybe_put_annotations(block, _annotations), do: block

  defp blocks_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) && block_value(&1, :type) == "text"))
    |> Enum.map_join(&(block_value(&1, :text) || ""))
  end

  defp block_value(block, key) when is_map(block) do
    Map.get(block, key) || Map.get(block, Atom.to_string(key))
  end

  defp block_value(_block, _key), do: nil
end
