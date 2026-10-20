defmodule Handbean.Agent.Provider.OpenAIStream do
  @moduledoc """
  Shared OpenAI-format SSE stream parser.

  Used by all OpenAI-compatible providers (OpenAI, DeepSeek, Mistral,
  OpenRouter, xAI, Ollama). Each provider calls `stream/5` with its
  own URL and headers; this module handles SSE parsing and response
  normalization.

  ## OpenAI Streaming Format

      data: {"choices":[{"index":0,"delta":{"content":"chunk"}}]}
      data: {"choices":[{"index":0,"delta":{"tool_calls":[...]}}]}
      data: [DONE]

  Text deltas are emitted via `on_chunk`. Tool call argument deltas
  are accumulated silently. The final response has the same shape as
  `complete/3`.
  """

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.SSE

  @max_trailing_whitespace_bytes 2048
  @default_receive_timeout 120_000

  @doc """
  Execute a streaming request against an OpenAI-compatible endpoint.

  Returns `{:ok, completion_response()} | {:error, term()}`.
  """
  @spec stream(String.t(), [{String.t(), String.t()}], map(), (String.t() -> :ok), keyword()) ::
          {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  def stream(url, headers, body, on_chunk, req_options) when is_function(on_chunk, 1) do
    tool_defs = tool_defs_from_body(body)

    body =
      body
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})

    initial_acc = %{
      buffer: "",
      content: "",
      reasoning_content: "",
      tool_calls: %{},
      finish_reason: nil,
      trailing_whitespace_bytes: 0,
      stream_error: nil,
      usage: %{},
      on_chunk: on_chunk,
      tool_defs: tool_defs
    }

    stream_handler = SSE.req_stream_handler(initial_acc, &handle_event/2)

    {req_mod, req_options} = Keyword.pop(req_options, :req_module, Req)

    req_opts =
      ([
         url: url,
         method: :post,
         headers: headers,
         body: Handbean.JSON.encode!(body),
         into: stream_handler
       ] ++ req_options)
      |> Keyword.put_new(:receive_timeout, @default_receive_timeout)
      |> Keyword.put(:retry, false)

    case req_mod.request(req_opts) do
      {:ok, %{status: 200} = resp} ->
        acc = Map.get(resp.private, :sse_acc, initial_acc)
        build_response(acc)

      {:ok, %{status: status} = resp} ->
        error_body = streaming_error_body(resp, initial_acc)
        {:error, parse_error(status, error_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp streaming_error_body(resp, initial_acc) do
    case resp.body do
      "" ->
        sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
        sse_acc.buffer

      body ->
        body
    end
  end

  # ── SSE Event Handling ───────────────────────────────────────────────

  @doc false
  def handle_event(acc, %{data: "[DONE]"}), do: acc

  def handle_event(acc, %{data: data}) do
    case Handbean.JSON.decode(data) do
      {:ok, parsed} when is_map(parsed) -> process_event(acc, parsed)
      _ -> {:halt, Map.put(acc, :stream_error, "Invalid JSON object in provider stream event")}
    end
  end

  @doc false
  def process_event(acc, %{"error" => _} = event) do
    {:halt, Map.put(acc, :stream_error, parse_error(200, event))}
  end

  def process_event(acc, %{"choices" => [choice | _]} = event) when is_map(choice) do
    acc = %{acc | usage: event["usage"] || acc.usage}
    delta = choice["delta"] || %{}

    with %{} = acc <- append_text(acc, delta["content"]) do
      acc =
        case delta do
          %{"reasoning_content" => text} when is_binary(text) and text != "" ->
            %{acc | reasoning_content: acc.reasoning_content <> text}

          _ ->
            acc
        end

      acc = accumulate_tool_calls(acc, Map.get(delta, "tool_calls", []))

      case choice do
        %{"finish_reason" => reason} when is_binary(reason) ->
          %{acc | finish_reason: reason}

        _ ->
          acc
      end
    end
  end

  def process_event(acc, %{"choices" => [], "usage" => usage}) when is_map(usage) do
    %{acc | usage: usage}
  end

  def process_event(acc, %{"usage" => usage}) when is_map(usage) do
    %{acc | usage: usage}
  end

  def process_event(acc, _event), do: acc

  defp append_text(acc, text) when is_binary(text) and text != "" do
    trimmed = String.trim_trailing(text)

    trailing =
      if trimmed == "",
        do: Map.get(acc, :trailing_whitespace_bytes, 0) + byte_size(text),
        else: byte_size(text) - byte_size(trimmed)

    if trailing >= @max_trailing_whitespace_bytes do
      error = "Provider emitted #{@max_trailing_whitespace_bytes} bytes of consecutive whitespace"

      # A single delta can contain both useful text and the runaway suffix.
      if trimmed != "", do: acc.on_chunk.(trimmed)

      {:halt, acc |> Map.put(:content, acc.content <> trimmed) |> Map.put(:stream_error, error)}
    else
      acc.on_chunk.(text)

      acc
      |> Map.put(:content, acc.content <> text)
      |> Map.put(:trailing_whitespace_bytes, trailing)
    end
  end

  defp append_text(acc, _text), do: acc

  # ── Tool Call Accumulation ───────────────────────────────────────────

  defp accumulate_tool_calls(acc, []), do: acc

  defp accumulate_tool_calls(acc, tool_call_deltas) do
    tool_calls =
      Enum.reduce(tool_call_deltas, acc.tool_calls, fn tc_delta, tool_calls ->
        index = tc_delta["index"]
        existing = Map.get(tool_calls, index, %{id: nil, name: nil, arguments_buffer: ""})

        existing =
          case tc_delta do
            %{"id" => id} -> %{existing | id: id}
            _ -> existing
          end

        existing =
          case get_in(tc_delta, ["function", "name"]) do
            nil -> existing
            name -> %{existing | name: name}
          end

        existing =
          case get_in(tc_delta, ["function", "arguments"]) do
            nil -> existing
            args -> %{existing | arguments_buffer: existing.arguments_buffer <> args}
          end

        Map.put(tool_calls, index, existing)
      end)

    %{acc | tool_calls: tool_calls}
  end

  # ── Response Building ────────────────────────────────────────────────

  @doc false
  def build_response(%{stream_error: error}) when not is_nil(error), do: {:error, error}

  def build_response(%{finish_reason: reason}) when reason not in ["stop", "tool_calls"] do
    error =
      case reason do
        "length" -> "Provider output truncated (finish_reason=length)"
        "content_filter" -> "Provider output blocked (finish_reason=content_filter)"
        nil -> "Provider stream ended with missing finish_reason"
        other -> "Provider stream ended with unsupported finish_reason=#{inspect(other)}"
      end

    {:error, error}
  end

  def build_response(%{finish_reason: "tool_calls", tool_calls: calls}) when map_size(calls) == 0,
    do: {:error, "Provider response announced tool calls but supplied none"}

  def build_response(acc) do
    reasoning_blocks =
      if acc.reasoning_content != "",
        do: [%{type: "thinking", thinking: acc.reasoning_content}],
        else: []

    text_blocks = if acc.content != "", do: [%{type: "text", text: acc.content}], else: []

    tool_blocks_result =
      acc.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.reduce_while([], fn {index, tc}, blocks ->
        input_result = decode_tool_arguments(tc.arguments_buffer)

        name = resolved_tool_name(tc, input_result, acc)

        case {input_result, name} do
          {{:ok, input}, name} when is_map(input) and is_binary(name) and name != "" ->
            # Streaming tool_call deltas from some providers (StepFun)
            # omit the top-level id and function name. Generate an id when
            # missing. Recover a name only when the arguments match exactly
            # one tool definition from this request.
            id = present(tc.id) || "call_#{index}"
            block = %{type: "tool_use", id: id, name: name, input: input}
            {:cont, [block | blocks]}

          {{:ok, input}, _} when not is_map(input) ->
            {:halt, {:error, "Invalid tool call JSON: expected an object"}}

          {{:ok, _input}, _} ->
            {:halt, {:error, "Missing or ambiguous tool call name"}}

          {{:error, :empty_arguments}, _} ->
            {:halt, {:error, "Invalid tool call JSON: empty arguments"}}

          {{:error, _reason}, _} ->
            {:halt, {:error, "Invalid tool call JSON: expected an object"}}
        end
      end)

    case tool_blocks_result do
      {:error, reason} ->
        {:error, reason}

      tool_blocks ->
        content_blocks = reasoning_blocks ++ text_blocks ++ Enum.reverse(tool_blocks)
        stop_reason = parse_finish_reason(acc.finish_reason)
        message = %Message{role: :assistant, content: content_blocks}

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [message],
           usage: Handbean.Agent.Provider.openai_usage(acc.usage),
           response_metadata: %{finish_reason: acc.finish_reason}
         }}
    end
  end

  defp resolved_tool_name(tc, {:ok, input}, acc) when is_map(input) do
    case present(tc.name) do
      name when is_binary(name) -> name
      _ -> unique_tool_name(input, Map.get(acc, :tool_defs, []))
    end
  end

  defp resolved_tool_name(_tc, _input_result, _acc), do: nil

  # OpenAI-compatible tool calls encode even a zero-argument input as the JSON
  # object "{}". Treat a missing arguments delta as an incomplete call instead
  # of manufacturing an empty map that could reach execution.
  defp decode_tool_arguments(""), do: {:error, :empty_arguments}
  defp decode_tool_arguments(arguments), do: Handbean.JSON.decode(arguments)

  defp unique_tool_name(input, tool_defs) when is_map(input) and is_list(tool_defs) do
    matches =
      Enum.filter(tool_defs, fn defn ->
        schema = function_schema(defn)
        required = required_keys(schema)
        properties = schema_map(schema, "properties")

        required != [] and
          Enum.all?(required, &Map.has_key?(input, &1)) and
          Enum.all?(Map.keys(input), &property?(properties, &1))
      end)

    case matches do
      [defn] -> function_name(defn)
      _ -> nil
    end
  end

  defp unique_tool_name(_input, _tool_defs), do: nil

  defp tool_defs_from_body(body) when is_map(body) do
    body
    |> Map.get("tools", Map.get(body, :tools, []))
    |> List.wrap()
  end

  defp tool_defs_from_body(_), do: []

  defp function_schema(%{"function" => function}) when is_map(function),
    do: schema_map(function, "parameters")

  defp function_schema(%{function: function}) when is_map(function),
    do: schema_map(function, "parameters")

  defp function_schema(_), do: %{}

  defp function_name(%{"function" => function}) when is_map(function),
    do: present(schema_get(function, "name"))

  defp function_name(%{function: function}) when is_map(function),
    do: present(schema_get(function, "name"))

  defp function_name(_), do: nil

  defp required_keys(schema) do
    schema
    |> schema_map("required")
    |> Enum.filter(&is_binary/1)
  end

  defp schema_map(map, key) when is_map(map) do
    case schema_get(map, key) do
      value when is_map(value) or is_list(value) -> value
      _ -> if key == "required", do: [], else: %{}
    end
  end

  defp schema_map(_, "required"), do: []
  defp schema_map(_, _), do: %{}

  defp property?(properties, key) when is_map(properties) and is_binary(key) do
    Map.has_key?(properties, key) or
      (existing_atom?(key) and Map.has_key?(properties, String.to_existing_atom(key)))
  end

  defp property?(_, _), do: false

  defp schema_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, schema_atom(key))
  end

  defp schema_atom("function"), do: :function
  defp schema_atom("parameters"), do: :parameters
  defp schema_atom("properties"), do: :properties
  defp schema_atom("required"), do: :required
  defp schema_atom("name"), do: :name

  defp existing_atom?(key) do
    _ = String.to_existing_atom(key)
    true
  rescue
    ArgumentError -> false
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp parse_finish_reason("stop"), do: :end_turn
  defp parse_finish_reason("tool_calls"), do: :tool_use

  defp parse_error(status, body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, %{"error" => _} = decoded} -> parse_error(status, decoded)
      _ -> "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"error" => error} when is_map(error) ->
        type = error["type"] || error["code"] || "provider_error"
        "#{type}: #{error["message"]}"

      _ ->
        "HTTP #{status}: #{inspect(body)}"
    end
  end
end
