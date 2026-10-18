defmodule Handbean.Agent.Provider.OpenAI do
  @moduledoc """
  Provider for OpenAI's Responses API.

  Normalizes OpenAI's response output items (assistant messages + function
  calls) to Handbean's content-block format.

  ## Config

  Required:
  - `:api_key` - OpenAI API key
  - `:model` - Model name (e.g., "gpt-5.4", "gpt-5.1", "o3-pro")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.openai.com")
  - `:base_url` - Alias for `:api_url` (Handbean convention)
  - `:provider_state` - opaque provider-owned state carried across turns
  - `:context_generation` - model-context generation; a mismatch drops continuation
  - `:use_previous_response_id` - Reuse provider response ids for continuation
  - `:store` - Persist the response server-side when supported
  - `:include` - Additional response fields to include
  - `:tool_choice` - Provider-native tool selection mode
  - `:parallel_tool_calls` - Whether the provider may issue tool calls in parallel
  - `:previous_response_id` - Explicit Responses continuation ID
  - `:reasoning` - Responses reasoning options, e.g. `%{effort: "medium"}`
  - `:built_in_tools` - provider-native tool definitions to append
  - `:web_search` - `true` or a config map to append a `web_search` tool
  - `:x_search` - `true` or a config map to append an `x_search` tool
  - `:receive_timeout` - Req idle/receive timeout in milliseconds (default: 180_000).
    For streaming this is the between-chunk timeout.
  - `:connect_timeout` - TCP connect timeout in milliseconds (default: 30_000)
  - `:req_options` - Additional options passed to Req
  - `:req_module` - HTTP client module, defaults to `Req` (tests may inject a mock)
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.SSE

  require Logger

  @default_api_url "https://api.openai.com"
  @default_max_tokens 4096
  # Streaming grok/xAI often pauses 30s+ between visible tokens while reasoning.
  # Req/Finch default idle timeout is ~15–30s and surfaces as TransportError :timeout.
  @default_receive_timeout 180_000
  @default_connect_timeout 30_000
  @loop_repetitions 8
  @min_loop_bytes 16
  @max_loop_bytes 512
  @repeated_output_error "Model stream stopped after detecting repeated output"

  @typedoc "Configuration for the OpenAI Responses provider."
  @type config :: %{
          required(:api_key) => String.t(),
          required(:model) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:api_url) => String.t(),
          optional(:base_url) => String.t(),
          optional(:provider_state) => map(),
          optional(:use_previous_response_id) => boolean(),
          optional(:store) => boolean(),
          optional(:include) => [String.t()],
          optional(:tool_choice) => String.t() | map(),
          optional(:parallel_tool_calls) => boolean(),
          optional(:previous_response_id) => String.t(),
          optional(:reasoning) => map(),
          optional(:built_in_tools) => [map()],
          optional(:web_search) => boolean() | map(),
          optional(:x_search) => boolean() | map(),
          optional(:receive_timeout) => pos_integer(),
          optional(:connect_timeout) => pos_integer(),
          optional(:req_module) => module(),
          optional(:req_options) => keyword()
        }

  @impl true
  def context_editing?, do: true

  @impl true
  @spec complete([Message.t()], [Handbean.Agent.Provider.tool_def()], config()) ::
          {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    config = normalize_config(config)
    body = build_request_body(messages, tool_defs, config)

    req_opts =
      build_req_opts(
        [
          url: "#{config.api_url}/v1/responses",
          method: :post,
          headers: request_headers(config),
          body: Handbean.JSON.encode!(body)
        ],
        config
      )

    case request(req_opts, config) do
      {:ok, %{status: 200, body: resp_body}} ->
        resp_body
        |> parse_response()
        |> tag_reasoning_origin(config)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, parse_error(status, resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  @spec stream([Message.t()], [Handbean.Agent.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    config = normalize_config(config)

    body =
      messages
      |> build_request_body(tool_defs, config)
      |> Map.put("stream", true)

    url = "#{config.api_url}/v1/responses"

    headers = request_headers(config)

    initial_acc = %{
      buffer: "",
      content: "",
      output: [],
      response: nil,
      stream_error: nil,
      on_chunk: on_chunk
    }

    stream_handler = SSE.req_stream_handler(initial_acc, &handle_stream_event/2)

    req_opts =
      build_req_opts(
        [
          url: url,
          method: :post,
          headers: headers,
          body: Handbean.JSON.encode!(body),
          into: stream_handler
        ],
        config
      )

    case request(req_opts, config) do
      {:ok, %{status: 200} = resp} ->
        acc = Map.get(resp.private, :sse_acc, initial_acc)
        build_stream_response(acc, config)

      {:ok, %{status: status} = resp} ->
        error_body = streaming_error_body(resp, initial_acc)
        {:error, parse_error(status, error_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    input_items = build_input_items(messages, config)

    body =
      %{
        "model" => config.model,
        "max_output_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
        "input" => input_items
      }
      |> maybe_put_previous_response_id(config)
      |> maybe_put_optional_request_field("store", Map.get(config, :store))
      |> maybe_put_optional_request_field("include", Map.get(config, :include))
      |> maybe_put_optional_request_field("tool_choice", Map.get(config, :tool_choice))
      |> maybe_put_optional_request_field(
        "parallel_tool_calls",
        Map.get(config, :parallel_tool_calls)
      )
      |> maybe_put_optional_request_field(
        "reasoning",
        Map.get(config, :reasoning) |> Handbean.Agent.Provider.stringify_keys()
      )

    tools =
      Enum.map(tool_defs, &format_tool_def/1) ++ built_in_tools(config)

    case tools do
      [] -> body
      defs -> Map.put(body, "tools", defs)
    end
  end

  defp maybe_put_previous_response_id(body, config) do
    previous_response_id =
      cond do
        context_fork?(config) ->
          nil

        Map.has_key?(config, :previous_response_id) ->
          Map.get(config, :previous_response_id)

        Map.get(config, :use_previous_response_id, false) and
            same_provider_context?(Map.get(config, :provider_state, %{}), config) ->
          get_in(config, [:provider_state, :response_id])

        true ->
          nil
      end

    maybe_put_optional_request_field(body, "previous_response_id", previous_response_id)
  end

  # An edited or compacted transcript is a new branch. The stored response id
  # still points at the server copy that contains the removed text.
  defp context_fork?(config) do
    requested = config[:context_generation] || 0
    bound = get_in(config, [:provider_state, :context_generation]) || 0
    requested != bound
  end

  defp maybe_put_optional_request_field(body, _key, nil), do: body
  defp maybe_put_optional_request_field(body, _key, value) when value == [], do: body
  defp maybe_put_optional_request_field(body, key, value), do: Map.put(body, key, value)

  defp built_in_tools(config) do
    []
    |> maybe_append_built_in_tool("web_search", Map.get(config, :web_search))
    |> maybe_append_built_in_tool("x_search", Map.get(config, :x_search))
    |> Kernel.++(normalize_built_in_tools(Map.get(config, :built_in_tools, [])))
  end

  defp maybe_append_built_in_tool(tools, _type, nil), do: tools
  defp maybe_append_built_in_tool(tools, _type, false), do: tools
  defp maybe_append_built_in_tool(tools, type, true), do: [%{"type" => type} | tools]

  defp maybe_append_built_in_tool(tools, "web_search", config) when is_map(config) do
    [normalize_web_search_tool(config) | tools]
  end

  defp maybe_append_built_in_tool(tools, type, config) when is_map(config) do
    [Map.put(Handbean.Agent.Provider.stringify_keys(config), "type", type) | tools]
  end

  defp normalize_built_in_tools(tools) when is_list(tools) do
    Enum.map(tools, &normalize_built_in_tool/1)
  end

  defp normalize_built_in_tools(_), do: []

  defp normalize_built_in_tool(%{"type" => _type} = tool),
    do: Handbean.Agent.Provider.stringify_keys(tool)

  defp normalize_built_in_tool(%{type: _type} = tool),
    do: Handbean.Agent.Provider.stringify_keys(tool)

  defp normalize_web_search_tool(config) do
    config
    |> Handbean.Agent.Provider.stringify_keys()
    |> Map.put("type", "web_search")
  end

  @doc false
  def build_input_items(messages, config) do
    system_items =
      case Map.get(config, :system_prompt) do
        nil -> []
        prompt -> [%{"role" => "system", "content" => prompt}]
      end

    convo_items =
      messages
      |> Handbean.Tool.Images.bound_history()
      |> Enum.flat_map(&format_input_item(&1, config))

    system_items ++ convo_items
  end

  defp format_input_item(%Message{role: :user, content: content}, _config)
       when is_binary(content) do
    [%{"role" => "user", "content" => content}]
  end

  defp format_input_item(%Message{role: :assistant, content: content}, _config)
       when is_binary(content) do
    [%{"role" => "assistant", "content" => content}]
  end

  defp format_input_item(%Message{role: :assistant, content: blocks}, config)
       when is_list(blocks) do
    Enum.flat_map(blocks, &format_assistant_block(&1, config))
  end

  defp format_input_item(%Message{role: :tool_result, content: blocks}, _config)
       when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{type: "tool_result", tool_use_id: tool_call_id, content: content} = block ->
        output =
          if block[:images] in [nil, []],
            do: content,
            else: Enum.map(Handbean.Tool.Images.content(block), &format_user_content_block/1)

        %{"type" => "function_call_output", "call_id" => tool_call_id, "output" => output}

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp format_input_item(%Message{role: :user, content: blocks}, _config)
       when is_list(blocks) do
    if Enum.any?(blocks, &(&1[:type] == "tool_result")) do
      blocks
      |> Enum.map(fn
        %{type: "tool_result", tool_use_id: tool_call_id, content: content} ->
          %{"type" => "function_call_output", "call_id" => tool_call_id, "output" => content}

        _other ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
    else
      parts = blocks |> Enum.map(&format_user_content_block/1) |> Enum.reject(&is_nil/1)

      case parts do
        [] -> []
        _ -> [%{"role" => "user", "content" => parts}]
      end
    end
  end

  defp format_assistant_block(%{type: "responses_reasoning", item: item} = block, config)
       when is_map(item) do
    if reasoning_replay_item?(item) and same_provider_context?(block, config),
      do: [stringify_reasoning_item(item)],
      else: []
  end

  defp format_assistant_block(
         %{"type" => "responses_reasoning", "item" => item} = block,
         config
       )
       when is_map(item) do
    if reasoning_replay_item?(item) and same_provider_context?(block, config),
      do: [stringify_reasoning_item(item)],
      else: []
  end

  defp format_assistant_block(%{type: "tool_use"} = block, _config) do
    [format_assistant_function_call_item(block)]
  end

  defp format_assistant_block(%{"type" => "tool_use"} = block, _config) do
    [format_assistant_function_call_item(block)]
  end

  defp format_assistant_block(%{type: "text", text: text}, _config)
       when is_binary(text) and text != "" do
    [%{"role" => "assistant", "content" => text}]
  end

  defp format_assistant_block(%{"type" => "text", "text" => text}, _config)
       when is_binary(text) and text != "" do
    [%{"role" => "assistant", "content" => text}]
  end

  defp format_assistant_block(_block, _config), do: []

  defp format_user_content_block(%{type: "text", text: text}) do
    %{"type" => "input_text", "text" => text}
  end

  defp format_user_content_block(%{type: "image", mime_type: mime_type, data: data}) do
    %{"type" => "input_image", "image_url" => "data:#{mime_type};base64,#{data}"}
  end

  defp format_user_content_block(%{type: "audio", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "video", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(%{type: "document", mime_type: mime_type}) do
    unsupported_media_notice(mime_type)
  end

  defp format_user_content_block(_block), do: nil

  defp unsupported_media_notice(mime_type) do
    %{
      "type" => "input_text",
      "text" => "[Unsupported media type for OpenAI provider: #{mime_type}]"
    }
  end

  @doc false
  def format_tool_def(%{name: name, description: desc, input_schema: schema}) do
    %{
      "type" => "function",
      "name" => name,
      "description" => desc,
      "parameters" => Handbean.Agent.Provider.stringify_keys(schema)
    }
  end

  defp format_assistant_function_call_item(block) when is_map(block) do
    id = Handbean.Utils.SafeMap.get_any(block, :id, "id")
    name = Handbean.Utils.SafeMap.get_any(block, :name, "name")
    input = Handbean.Utils.SafeMap.get_any(block, :input, "input") || %{}

    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => name,
      "arguments" => Handbean.JSON.encode!(input)
    }
  end

  defp reasoning_replay_item?(item) when is_map(item) do
    type = Handbean.Utils.SafeMap.get_any(item, "type", :type)

    encrypted =
      Handbean.Utils.SafeMap.get_any(item, "encrypted_content", :encrypted_content)

    type == "reasoning" and is_binary(encrypted) and encrypted != ""
  end

  defp same_provider_context?(value, config) do
    source = Handbean.Utils.SafeMap.get_any(value, :provider_context, "provider_context")

    is_map(source) and reasoning_origin(source) == reasoning_origin(config)
  end

  defp reasoning_origin(config) when is_map(config) do
    %{
      provider:
        identity_value(
          Handbean.Utils.SafeMap.get_any(config, :provider_key, "provider_key") ||
            Handbean.Utils.SafeMap.get_any(config, :provider, "provider") ||
            Handbean.Utils.SafeMap.get_any(config, :api_url, "api_url") ||
            Handbean.Utils.SafeMap.get_any(config, :base_url, "base_url") ||
            @default_api_url
        ),
      api:
        identity_value(Handbean.Utils.SafeMap.get_any(config, :api, "api") || :openai_responses),
      model: identity_value(Handbean.Utils.SafeMap.get_any(config, :model, "model"))
    }
  end

  defp identity_value(nil), do: nil
  defp identity_value(value) when is_atom(value), do: Atom.to_string(value)
  defp identity_value(value) when is_binary(value), do: value
  defp identity_value(value), do: to_string(value)

  defp stringify_reasoning_item(item) do
    item
    |> Handbean.Agent.Provider.stringify_keys()
    |> Map.take(["type", "id", "summary", "encrypted_content", "status"])
  end

  # --- Streaming ---

  defp streaming_error_body(resp, initial_acc) do
    case resp.body do
      "" ->
        sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
        sse_acc.buffer

      body ->
        body
    end
  end

  defp handle_stream_event(acc, %{data: "[DONE]"}), do: acc

  defp handle_stream_event(acc, %{event: event_name, data: data}) do
    case Handbean.JSON.decode(data) do
      {:ok, parsed} when is_map(parsed) ->
        event_type = event_name || Map.get(parsed, "type")
        process_stream_event(acc, event_type, parsed)

      _ ->
        {:halt, %{acc | stream_error: "Invalid JSON object in OpenAI stream event"}}
    end
  end

  defp process_stream_event(acc, "response.output_text.delta", %{"delta" => delta})
       when is_binary(delta) and delta != "" do
    content = acc.content <> delta

    case repeated_suffix(content) do
      {:repeated, period} ->
        repeated_bytes = period * @loop_repetitions
        pattern = binary_part(content, byte_size(content) - repeated_bytes, period)

        Logger.warning(
          "[OpenAI] repeated stream output detected " <>
            "period_bytes=#{period} repeated_bytes=#{repeated_bytes} " <>
            "accumulated_bytes=#{byte_size(content)} #{log_chunk(pattern)}"
        )

        {:halt, %{acc | content: content, stream_error: @repeated_output_error}}

      :none ->
        acc.on_chunk.(delta)
        %{acc | content: content}
    end
  end

  defp process_stream_event(acc, "response.output_text.done", %{"text" => text})
       when is_binary(text) and text != "" do
    Logger.debug("[OpenAI] stream output_text.done #{log_chunk(text)}")
    %{acc | content: prefer_longer_text(acc.content, text)}
  end

  defp process_stream_event(acc, "response.content_part.done", %{
         "item_id" => item_id,
         "part" => part
       })
       when is_map(part) do
    %{acc | output: merge_stream_output_part(acc.output, item_id, part)}
  end

  defp process_stream_event(acc, "response.output_item.done", %{"item" => item})
       when is_map(item) do
    Logger.debug(
      "[OpenAI] stream output_item.done type=#{inspect(item["type"])} " <>
        "role=#{inspect(item["role"])} name=#{inspect(item["name"])}"
    )

    case parse_output_item(item) do
      {:ok, _blocks} -> %{acc | output: upsert_stream_output_item(acc.output, item)}
      {:error, reason} -> {:halt, %{acc | stream_error: reason}}
    end
  end

  defp process_stream_event(acc, "response.completed", %{"response" => response})
       when is_map(response) do
    Logger.debug(
      "[OpenAI] stream completed response_id=#{inspect(response["id"])} " <>
        "output_count=#{length(response["output"] || [])} accumulated_bytes=#{byte_size(acc.content)} " <>
        "accumulated_output_count=#{length(acc.output || [])}"
    )

    %{acc | response: merge_stream_response(response, acc)}
  end

  defp process_stream_event(acc, "response.failed", payload) do
    {:halt, %{acc | stream_error: parse_stream_event_error(payload)}}
  end

  defp process_stream_event(acc, "response.incomplete", _payload) do
    {:halt, %{acc | stream_error: "OpenAI response incomplete"}}
  end

  defp process_stream_event(acc, "error", payload) do
    {:halt, %{acc | stream_error: parse_stream_event_error(payload)}}
  end

  defp process_stream_event(acc, _event_type, _payload), do: acc

  defp repeated_suffix(content) do
    max_period = min(@max_loop_bytes, div(byte_size(content), @loop_repetitions))

    if max_period < @min_loop_bytes do
      :none
    else
      case Enum.find(@min_loop_bytes..max_period, &repeated_period?(content, &1)) do
        nil -> :none
        period -> {:repeated, period}
      end
    end
  end

  defp repeated_period?(content, period) do
    repeated_bytes = period * @loop_repetitions
    offset = byte_size(content) - repeated_bytes
    suffix = binary_part(content, offset, repeated_bytes)
    pattern = binary_part(suffix, 0, period)

    suffix == :binary.copy(pattern, @loop_repetitions) and substantive_pattern?(pattern)
  end

  # Box-drawing rules, `====`, and table separators are formatting, not a loop.
  # A repeated unit must contain a letter or digit before it counts.
  defp substantive_pattern?(pattern) do
    String.match?(pattern, ~r/[\p{L}\p{N}]/u)
  end

  defp build_stream_response(%{stream_error: error}, _config) when is_binary(error) do
    {:error, error}
  end

  defp build_stream_response(%{response: response} = acc, config) when is_map(response) do
    response = merge_stream_response(response, acc)

    Logger.debug(
      "[OpenAI] build stream response output_count=#{length(response["output"] || [])} " <>
        "fallback_bytes=#{byte_size(Map.get(response, "output_text", ""))}"
    )

    response
    |> parse_response()
    |> tag_reasoning_origin(config)
  end

  defp build_stream_response(_acc, _config) do
    {:error, "OpenAI stream ended without response.completed"}
  end

  defp parse_stream_event_error(payload) do
    error = Map.get(payload, "error") || get_in(payload, ["response", "error"])

    case error do
      nil -> "provider_error: Provider returned a failed response"
      error -> format_error_payload(error)
    end
  end

  defp prefer_longer_text(current, candidate) do
    if byte_size(candidate) > byte_size(current), do: candidate, else: current
  end

  defp merge_stream_output_part(
         output,
         item_id,
         %{"type" => "output_text", "text" => text} = part
       )
       when is_binary(text) and text != "" do
    part = Map.take(part, ["annotations", "text", "type"])

    upsert_stream_output_item(output, %{
      "id" => item_id,
      "type" => "message",
      "role" => "assistant",
      "content" => [part]
    })
  end

  defp merge_stream_output_part(output, _item_id, _part), do: output

  defp upsert_stream_output_item(output, %{"type" => "message", "role" => "assistant"} = item) do
    upsert_stream_output_item_by_id(output, item)
  end

  defp upsert_stream_output_item(output, %{"type" => "function_call"} = item) do
    upsert_stream_output_item_by_id(output, item)
  end

  defp upsert_stream_output_item(output, %{"type" => "reasoning"} = item) do
    upsert_stream_output_item_by_id(output, item)
  end

  defp upsert_stream_output_item(output, _item), do: output

  defp upsert_stream_output_item_by_id(output, item) do
    case Enum.find_index(output, &same_stream_output_item?(&1, item)) do
      nil -> [item | output]
      index -> List.replace_at(output, index, item)
    end
  end

  defp same_stream_output_item?(%{"id" => id}, %{"id" => id}) when is_binary(id), do: true

  defp same_stream_output_item?(%{"call_id" => id}, %{"call_id" => id}) when is_binary(id),
    do: true

  defp same_stream_output_item?(_existing, _item), do: false

  defp merge_stream_response(response, acc) do
    response
    |> maybe_put_stream_output(acc.output)
    |> maybe_put_stream_output_text(acc.content)
  end

  defp maybe_put_stream_output(%{"output" => output} = response, stream_output)
       when is_list(output) and output != [] do
    if stream_output == [], do: response, else: Map.put(response, "output", output)
  end

  defp maybe_put_stream_output(response, stream_output) when is_list(stream_output) do
    if stream_output == [], do: response, else: Map.put(response, "output", stream_output)
  end

  defp maybe_put_stream_output(response, _stream_output), do: response

  defp maybe_put_stream_output_text(response, content)
       when is_binary(content) and content != "" do
    case response_text_fallback(response) do
      nil -> Map.put(response, "output_text", content)
      _text -> response
    end
  end

  defp maybe_put_stream_output_text(response, _content), do: response

  # --- Response Parsing ---

  @doc false
  def parse_response(body) when is_binary(body) do
    case Handbean.Agent.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  def parse_response(%{"error" => error}) when not is_nil(error) do
    {:error, format_error_payload(error)}
  end

  def parse_response(%{"status" => status}) when status not in [nil, "completed"] do
    {:error, "OpenAI response did not complete successfully"}
  end

  def parse_response(%{"output" => output} = resp) when is_list(output) do
    usage = resp["usage"] || %{}
    provider_state = provider_state_from_response(resp)

    case parse_output_to_blocks(output) do
      {:ok, content_blocks} ->
        content_blocks = fallback_response_text_blocks(resp, content_blocks)
        stop_reason = parse_stop_reason(content_blocks)

        Logger.debug(
          "[OpenAI] parsed response stop_reason=#{stop_reason} blocks=#{length(content_blocks)} " <>
            "text_bytes=#{byte_size(blocks_text(content_blocks))}"
        )

        alloy_msg = %Message{
          role: :assistant,
          content: content_blocks
        }

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [alloy_msg],
           usage: Handbean.Agent.Provider.openai_usage(usage),
           provider_state: provider_state,
           response_metadata: response_metadata_from_response(resp)
         }}

      {:error, _} = err ->
        err
    end
  end

  def parse_response(%{"output_text" => text} = resp) when is_binary(text) do
    usage = resp["usage"] || %{}
    provider_state = provider_state_from_response(resp)

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
       response_metadata: response_metadata_from_response(resp)
     }}
  end

  def parse_response(_resp) do
    {:error, "Unexpected OpenAI response payload"}
  end

  defp parse_output_to_blocks(output) do
    result =
      Enum.reduce_while(output, {:ok, []}, fn item, {:ok, acc} ->
        case parse_output_item(item) do
          {:ok, blocks} -> {:cont, {:ok, [blocks | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, nested} -> {:ok, nested |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp fallback_response_text_blocks(resp, [] = _content_blocks) do
    resp
    |> response_text_fallback()
    |> case do
      nil -> []
      text -> [%{type: "text", text: text}]
    end
  end

  defp fallback_response_text_blocks(_resp, content_blocks), do: content_blocks

  defp response_text_fallback(resp) do
    Enum.find_value(["output_text", "text", "message"], fn key ->
      case Map.get(resp, key) do
        text when is_binary(text) and text != "" -> text
        _other -> nil
      end
    end)
  end

  defp parse_output_item(%{"type" => "message", "role" => "assistant", "content" => content})
       when is_list(content) do
    if Enum.any?(content, &malformed_assistant_part?/1),
      do: {:error, "Malformed OpenAI assistant content"},
      else: {:ok, parse_assistant_content(content)}
  end

  defp parse_output_item(%{"type" => "message", "role" => "assistant", "content" => text})
       when is_binary(text) do
    blocks =
      case text do
        "" -> []
        _ -> [%{type: "text", text: text}]
      end

    {:ok, blocks}
  end

  defp parse_output_item(%{"type" => "function_call", "name" => name} = call)
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

  defp parse_output_item(%{"type" => "reasoning", "encrypted_content" => encrypted} = item)
       when is_binary(encrypted) and encrypted != "" do
    {:ok,
     [
       %{
         type: "responses_reasoning",
         item: Map.take(item, ["type", "id", "summary", "encrypted_content", "status"])
       }
     ]}
  end

  defp parse_output_item(%{"type" => type}) when type in ["function_call", "message"],
    do: {:error, "Malformed OpenAI #{type}"}

  defp parse_output_item(_item), do: {:ok, []}

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
    args = call["arguments"]

    case args do
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

  defp parse_error(status, body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, %{"error" => error}} ->
        format_error_payload(error)

      _ ->
        "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"error" => error} -> format_error_payload(error)
      _ -> "HTTP #{status}: #{inspect(body)}"
    end
  end

  defp format_error_payload(error) when is_map(error) do
    type = Map.get(error, "type") || Map.get(error, "code") || "error"
    message = Map.get(error, "message") || "Provider request failed"
    "#{type}: #{message}"
  end

  defp format_error_payload(error) when is_binary(error), do: error
  defp format_error_payload(_error), do: "provider_error: Provider request failed"

  defp tag_reasoning_origin({:ok, %{messages: messages} = response}, config) do
    origin = reasoning_origin(config)

    tagged =
      Enum.map(messages, fn
        %Message{content: blocks} = message when is_list(blocks) ->
          %{message | content: Enum.map(blocks, &tag_reasoning_block(&1, origin))}

        message ->
          message
      end)

    {:ok,
     response
     |> Map.put(:messages, tagged)
     |> Map.update(:provider_state, %{provider_context: origin}, fn provider_state ->
       Map.put(provider_state, :provider_context, origin)
     end)}
  end

  defp tag_reasoning_origin(result, _config), do: result

  defp tag_reasoning_block(%{type: "responses_reasoning"} = block, origin),
    do: Map.put(block, :provider_context, origin)

  defp tag_reasoning_block(%{"type" => "responses_reasoning"} = block, origin),
    do: Map.put(block, "provider_context", origin)

  defp tag_reasoning_block(block, _origin), do: block

  defp provider_state_from_response(%{"id" => id}) when is_binary(id) and id != "" do
    %{response_id: id}
  end

  defp provider_state_from_response(_resp), do: %{}

  defp response_metadata_from_response(resp) do
    %{}
    |> maybe_put_response_metadata(:citations, Map.get(resp, "citations"))
    |> maybe_put_response_metadata(
      :server_side_tool_usage,
      Map.get(resp, "server_side_tool_usage")
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

  defp log_chunk(chunk) when is_binary(chunk) do
    preview =
      chunk
      |> String.slice(0, 40)
      |> String.replace(~r/\s+/, " ")

    "bytes=#{byte_size(chunk)} preview=#{inspect(preview)}"
  end

  defp blocks_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) && block_value(&1, :type) == "text"))
    |> Enum.map_join(&(block_value(&1, :text) || ""))
  end

  defp block_value(block, key) when is_map(block) do
    Map.get(block, key) || Map.get(block, Atom.to_string(key))
  end

  defp block_value(_block, _key), do: nil

  # ── Config normalization ─────────────────────────────────────────────

  defp normalize_config(config) do
    Map.put_new(config, :api_url, config[:base_url] || @default_api_url)
  end

  defp request_headers(config) do
    [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"}
    ] ++ Map.get(config, :extra_headers, [])
  end

  defp build_req_opts(base, config) do
    receive_timeout = Map.get(config, :receive_timeout, @default_receive_timeout)
    connect_timeout = Map.get(config, :connect_timeout, @default_connect_timeout)

    base
    |> Keyword.merge(
      receive_timeout: receive_timeout,
      connect_options: [timeout: connect_timeout]
    )
    |> Keyword.merge(Map.get(config, :req_options, []))
    |> Keyword.put(:retry, false)
  end

  defp request(req_opts, config) do
    req_mod = Map.get(config, :req_module, Req)
    req_mod.request(req_opts)
  end
end
