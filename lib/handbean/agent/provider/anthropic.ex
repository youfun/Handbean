defmodule Handbean.Agent.Provider.Anthropic do
  @moduledoc """
  Provider for Anthropic's Claude Messages API.

  Uses Req for HTTP calls. Since Anthropic's wire format uses content blocks
  (the most expressive format), this provider has the simplest normalization.

  ## Config

  Required:
  - `:api_key` - Anthropic API key
  - `:model` - Model name (e.g., "claude-opus-4-6",
    "claude-sonnet-4-6", "claude-haiku-4-5")

  Optional:
  - `:max_tokens` - Max output tokens (default: 4096)
  - `:system_prompt` - System prompt string
  - `:api_url` - Base URL (default: "https://api.anthropic.com")
  - `:base_url` - Alias for `:api_url` (Handbean convention)
  - `:api_version` - API version header (default: "2023-06-01")
  - `:extra_headers` - Additional headers as `[{name, value}]`
  - `:req_options` - Additional options passed to Req (useful for testing)
  - `:receive_timeout` - Req receive timeout in milliseconds (default: 120_000).
    For streaming, this governs the between-chunk timeout; for non-streaming
    it is the total response timeout.
  - `:retry_count` - Additional retries for transient transport errors
    (`:closed`, `:timeout`) at the Req level (default: 2).
  - `:extended_thinking` - Enable extended thinking. Pass a keyword list with
    `:budget_tokens` (e.g., `[budget_tokens: 5000]`). Thinking blocks are
    returned in the message content and must be round-tripped verbatim in
    subsequent turns (Anthropic requires the `signature` field).
  - `:on_event` - Streaming event callback `(event -> :ok)`. Called for each
    streaming delta.
  - `:cache` - Enable Anthropic prompt caching (default: false).

  ## Example

      Handbean.Agent.run("What is Elixir?",
        provider: {Handbean.Agent.Provider.Anthropic,
          api_key: System.get_env("ANTHROPIC_API_KEY"),
          model: "claude-sonnet-4-6"
        }
      )
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.SSE

  @default_api_url "https://api.anthropic.com"
  @default_api_version "2023-06-01"
  @default_max_tokens 4096
  @default_receive_timeout 120_000
  @default_retry_count 2

  @typedoc """
  Configuration for the Anthropic provider. See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:api_key) => String.t(),
          required(:model) => String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:api_url) => String.t(),
          optional(:base_url) => String.t(),
          optional(:api_version) => String.t(),
          optional(:extra_headers) => [{String.t(), String.t()}],
          optional(:req_options) => keyword(),
          optional(:receive_timeout) => pos_integer(),
          optional(:retry_count) => non_neg_integer(),
          optional(:extended_thinking) => keyword(),
          optional(:on_event) => (term() -> :ok),
          optional(:cache) => boolean()
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
      ([
         url: "#{config.api_url}/v1/messages",
         method: :post,
         headers: build_headers(config),
         body: Handbean.JSON.encode!(body)
       ] ++ default_req_options(config) ++ Map.get(config, :req_options, []))
      |> Keyword.put(:retry, false)

    case request_with_retry(req_opts, Map.get(config, :retry_count, @default_retry_count), config) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, parse_error(status, resp_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Stream a completion using Anthropic's SSE streaming API.

  Calls `on_chunk` for each text delta as it arrives. Accumulates all
  content blocks and returns the same `{:ok, completion_response()}` shape
  as `complete/3` once the stream finishes.
  """
  @impl true
  @spec stream([Message.t()], [Handbean.Agent.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    config = normalize_config(config)

    body =
      build_request_body(messages, tool_defs, config)
      |> Map.put("stream", true)

    on_event = Map.get(config, :on_event, fn _ -> :ok end)

    initial_acc = %{
      buffer: "",
      content_blocks: %{},
      input_json_buffers: %{},
      stop_reason: nil,
      message_stopped?: false,
      stream_error: nil,
      usage: %{},
      on_chunk: on_chunk,
      on_event: on_event
    }

    stream_handler = SSE.req_stream_handler(initial_acc, &handle_sse_raw_event/2)

    req_opts =
      ([
         url: "#{config.api_url}/v1/messages",
         method: :post,
         headers: build_headers(config),
         body: Handbean.JSON.encode!(body),
         into: stream_handler
       ] ++ default_req_options(config) ++ Map.get(config, :req_options, []))
      |> Keyword.put(:retry, false)

    case request_with_retry(req_opts, Map.get(config, :retry_count, @default_retry_count), config) do
      {:ok, %{status: 200} = resp} ->
        sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
        build_stream_response(sse_acc)

      {:ok, %{status: status} = resp} ->
        error_body = streaming_error_body(resp, initial_acc)
        {:error, parse_error(status, error_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # When streaming (into: handler), the error body is consumed by the SSE
  # callback and resp.body is left as "". Recover it from the SSE buffer.
  defp streaming_error_body(resp, initial_acc) do
    case resp.body do
      "" ->
        sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
        sse_acc.buffer

      body ->
        body
    end
  end

  # Bridge from SSE module's raw events to Anthropic's typed event handler.
  defp handle_sse_raw_event(acc, %{event: event_type, data: data}) when is_binary(event_type) do
    case Handbean.JSON.decode(data) do
      {:ok, parsed} when is_map(parsed) -> handle_sse_event(acc, event_type, parsed)
      _ -> {:halt, %{acc | stream_error: "Invalid JSON object in Anthropic stream event"}}
    end
  end

  defp handle_sse_raw_event(acc, _event), do: acc

  defp handle_sse_event(acc, "message_start", %{"message" => msg}) do
    usage = Map.get(msg, "usage", %{})
    %{acc | usage: merge_sse_usage(acc.usage, usage)}
  end

  defp handle_sse_event(acc, "content_block_start", %{
         "index" => index,
         "content_block" => block
       }) do
    put_in(acc.content_blocks[index], block)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "thinking_delta", "thinking" => text}
       }) do
    acc.on_event.({:thinking_delta, text})

    current = Map.get(acc.content_blocks, index, %{"type" => "thinking", "thinking" => ""})
    updated = Map.update!(current, "thinking", &(&1 <> text))
    put_in(acc.content_blocks[index], updated)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "signature_delta", "signature" => sig}
       }) do
    current = Map.get(acc.content_blocks, index, %{"type" => "thinking", "thinking" => ""})
    updated = Map.put(current, "signature", sig)
    put_in(acc.content_blocks[index], updated)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    acc.on_chunk.(text)

    current = Map.get(acc.content_blocks, index, %{"type" => "text", "text" => ""})
    updated = Map.update!(current, "text", &(&1 <> text))
    put_in(acc.content_blocks[index], updated)
  end

  defp handle_sse_event(acc, "content_block_delta", %{
         "index" => index,
         "delta" => %{"type" => "input_json_delta", "partial_json" => json}
       }) do
    # Accumulate partial JSON for tool_use input
    current_buffer = Map.get(acc.input_json_buffers, index, "")
    %{acc | input_json_buffers: Map.put(acc.input_json_buffers, index, current_buffer <> json)}
  end

  defp handle_sse_event(acc, "content_block_stop", %{"index" => index}) do
    case Map.fetch(acc.input_json_buffers, index) do
      :error ->
        acc

      {:ok, json_str} ->
        case Handbean.JSON.decode(json_str) do
          {:ok, input} when is_map(input) ->
            current = Map.fetch!(acc.content_blocks, index)
            updated = Map.put(current, "input", input)

            acc
            |> put_in([Access.key(:content_blocks), index], updated)
            |> Map.put(:input_json_buffers, Map.delete(acc.input_json_buffers, index))

          _ ->
            {:halt, %{acc | stream_error: "Invalid JSON in Anthropic tool call arguments"}}
        end
    end
  end

  defp handle_sse_event(acc, "error", payload) do
    error =
      payload
      |> Handbean.Log.Redactor.redact()
      |> then(&parse_error(200, &1))
      |> String.slice(0, 2_000)

    {:halt, %{acc | stream_error: error}}
  end

  defp handle_sse_event(acc, "message_stop", _payload), do: %{acc | message_stopped?: true}

  defp handle_sse_event(acc, "message_delta", %{"delta" => delta, "usage" => usage}) do
    stop_reason = Map.get(delta, "stop_reason")
    %{acc | stop_reason: stop_reason, usage: merge_sse_usage(acc.usage, usage)}
  end

  defp handle_sse_event(acc, "message_delta", %{"delta" => delta}) do
    stop_reason = Map.get(delta, "stop_reason")
    %{acc | stop_reason: stop_reason}
  end

  defp handle_sse_event(acc, _event_type, _data), do: acc

  defp merge_sse_usage(existing, new) do
    Map.merge(existing, new, fn _k, v1, v2 ->
      if is_number(v1) and is_number(v2), do: v1 + v2, else: v2
    end)
  end

  defp build_stream_response(%{stream_error: error}) when is_binary(error), do: {:error, error}

  defp build_stream_response(%{message_stopped?: false}),
    do: {:error, "Anthropic stream ended without message_stop"}

  defp build_stream_response(%{input_json_buffers: buffers}) when map_size(buffers) > 0,
    do: {:error, "Anthropic stream ended with unfinished tool call arguments"}

  defp build_stream_response(acc) do
    blocks =
      acc.content_blocks
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, block} -> block end)

    parse_response(%{
      "type" => "message",
      "content" => blocks,
      "stop_reason" => acc.stop_reason,
      "usage" => acc.usage
    })
  end

  # --- Request Building ---

  defp build_request_body(messages, tool_defs, config) do
    cache? = Map.get(config, :cache, false)

    formatted_messages =
      messages
      |> Handbean.Tool.Images.bound_history()
      |> Enum.map(&format_message/1)
      |> maybe_add_cache_to_last_user_message(cache?, config)

    body = %{
      "model" => config.model,
      "max_tokens" => Map.get(config, :max_tokens, @default_max_tokens),
      "messages" => formatted_messages
    }

    body =
      case Map.get(config, :system_prompt) do
        nil ->
          body

        prompt when cache? ->
          dynamic_suffix = Map.get(config, :cache_dynamic_suffix)

          system_blocks =
            if is_binary(dynamic_suffix) and dynamic_suffix != "" do
              # Split: cached stable prefix + uncached dynamic suffix
              # so that workspace-specific info refreshes each turn
              # without breaking the cache on AGENTS.md / core instructions.
              stable = String.replace_suffix(prompt, dynamic_suffix, "")

              [
                %{
                  "type" => "text",
                  "text" => stable,
                  "cache_control" => %{"type" => "ephemeral"}
                },
                %{"type" => "text", "text" => dynamic_suffix}
              ]
            else
              [
                %{
                  "type" => "text",
                  "text" => prompt,
                  "cache_control" => %{"type" => "ephemeral"}
                }
              ]
            end

          Map.put(body, "system", system_blocks)

        prompt ->
          Map.put(body, "system", prompt)
      end

    body =
      case tool_defs do
        [] ->
          body

        defs ->
          tools = Enum.map(defs, &format_tool_def/1)
          tools = maybe_add_cache_to_last_tool(tools, cache?)
          Map.put(body, "tools", tools)
      end

    case Map.get(config, :extended_thinking) do
      nil ->
        body

      opts when is_list(opts) ->
        budget = Keyword.get(opts, :budget_tokens)

        unless is_integer(budget) and budget > 0 do
          raise ArgumentError,
                "extended_thinking requires a positive integer :budget_tokens, got: #{inspect(budget)}"
        end

        Map.put(body, "thinking", %{"type" => "enabled", "budget_tokens" => budget})

      _opts ->
        body
    end
  end

  defp build_headers(config) do
    ([
       auth_header(config),
       {"anthropic-version", Map.get(config, :api_version, @default_api_version)},
       {"content-type", "application/json"},
       {"user-agent", Map.get(config, :user_agent) || "pi-coding-agent"}
     ] ++ Map.get(config, :extra_headers, []))
    |> drop_overridden_headers()
  end

  # extra_headers win when a subscription adapter replaces the default identity.
  defp drop_overridden_headers(headers) do
    {kept, _seen} =
      Enum.reduce(Enum.reverse(headers), {[], MapSet.new()}, fn {name, value}, {acc, seen} ->
        key = String.downcase(name)

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {[{name, value} | acc], MapSet.put(seen, key)}
        end
      end)

    kept
  end

  # Ollama Cloud and OpenCode Go reject x-api-key-only auth. Their Messages
  # routes require the same bearer token as Chat Completions.
  defp auth_header(%{auth_header: "authorization"} = config),
    do: {"authorization", "Bearer #{config.api_key}"}

  defp auth_header(%{provider: provider} = config)
       when provider in ["ollama", "opencode-go"],
       do: {"authorization", "Bearer #{config.api_key}"}

  defp auth_header(config), do: {"x-api-key", config.api_key}

  defp format_message(%Message{role: :tool_result, content: blocks}) when is_list(blocks) do
    %{"role" => "user", "content" => Enum.map(blocks, &format_content_block/1)}
  end

  defp format_message(%Message{role: :tool_result, content: content}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp format_message(%Message{role: role, content: content}) when is_binary(content) do
    %{"role" => to_string(role), "content" => content}
  end

  defp format_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    %{"role" => to_string(role), "content" => Enum.map(blocks, &format_content_block/1)}
  end

  defp format_content_block(%{type: "thinking", thinking: thinking} = block) do
    %{"type" => "thinking", "thinking" => thinking}
    |> maybe_put("signature", block[:signature])
  end

  defp format_content_block(%{type: "text", text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp format_content_block(%{type: "tool_use", id: id, name: name, input: input}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp format_content_block(%{type: "tool_result", tool_use_id: id, content: content} = block) do
    content =
      if block[:images] in [nil, []],
        do: content,
        else: Enum.map(Handbean.Tool.Images.content(block), &format_content_block/1)

    result = %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
    if Map.get(block, :is_error), do: Map.put(result, "is_error", true), else: result
  end

  defp format_content_block(%{type: "server_tool_use", id: id, name: name, input: input}) do
    %{"type" => "server_tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp format_content_block(
         %{
           type: "server_tool_result",
           tool_use_id: id,
           content: content
         } = block
       ) do
    result = %{"type" => "server_tool_result", "tool_use_id" => id, "content" => content}
    if Map.get(block, :is_error), do: Map.put(result, "is_error", true), else: result
  end

  defp format_content_block(%{type: "image", mime_type: mime_type, data: data}) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => mime_type,
        "data" => data
      }
    }
  end

  defp format_content_block(%{type: type}) when type in ["audio", "video"] do
    %{"type" => "text", "text" => "[Unsupported media type for Anthropic provider: #{type}]"}
  end

  defp format_content_block(%{type: "document", mime_type: mime_type}) do
    %{
      "type" => "text",
      "text" =>
        "[Unsupported inline document (#{mime_type}) for Anthropic provider: use the Files API]"
    }
  end

  defp format_content_block(block) when is_map(block) do
    Map.new(block, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_add_cache_to_last_tool([], _cache?), do: []
  defp maybe_add_cache_to_last_tool(tools, false), do: tools

  defp maybe_add_cache_to_last_tool(tools, true) do
    {init, [last]} = Enum.split(tools, -1)
    init ++ [Map.put(last, "cache_control", %{"type" => "ephemeral"})]
  end

  # Adds cache_control to the last real user message's last content block.
  # A compaction fork keeps that marker on the parent prefix and leaves the
  # appended summary instruction unmarked.
  defp maybe_add_cache_to_last_user_message(messages, false, _config), do: messages

  defp maybe_add_cache_to_last_user_message(messages, true, config) do
    suffix = if Map.get(config, :cache_fork), do: Map.get(config, :cache_fork_suffix, 1), else: 0

    if is_integer(suffix) and suffix > 0 and suffix < length(messages) do
      {parent, tail} = Enum.split(messages, length(messages) - suffix)
      maybe_add_cache_to_last_user_message(parent, true) ++ tail
    else
      maybe_add_cache_to_last_user_message(messages, true)
    end
  end

  defp maybe_add_cache_to_last_user_message([], _cache?), do: []

  defp maybe_add_cache_to_last_user_message(messages, true) do
    # Find the last real user message (not a tool_result)
    index =
      messages
      |> Enum.reverse()
      |> Enum.find_index(fn msg ->
        msg["role"] == "user" and
          (is_binary(msg["content"]) or
             not Enum.any?(
               msg["content"] || [],
               &(&1["type"] in ["tool_result", "server_tool_result"])
             ))
      end)

    case index do
      nil ->
        messages

      idx ->
        real_idx = length(messages) - 1 - idx
        msg = Enum.at(messages, real_idx)

        updated_msg =
          case msg["content"] do
            blocks when is_list(blocks) and blocks != [] ->
              {init, [last]} = Enum.split(blocks, -1)
              updated_last = Map.put(last, "cache_control", %{"type" => "ephemeral"})
              Map.put(msg, "content", init ++ [updated_last])

            text when is_binary(text) ->
              Map.put(msg, "content", [
                %{
                  "type" => "text",
                  "text" => text,
                  "cache_control" => %{"type" => "ephemeral"}
                }
              ])

            _ ->
              msg
          end

        List.replace_at(messages, real_idx, updated_msg)
    end
  end

  defp format_tool_def(%{name: name, description: desc, input_schema: schema} = def_map) do
    base = %{
      "name" => name,
      "description" => desc,
      "input_schema" => Handbean.Agent.Provider.stringify_keys(schema)
    }

    case Map.get(def_map, :allowed_callers) do
      nil -> base
      callers -> Map.put(base, "allowed_callers", Enum.map(callers, &to_string/1))
    end
  end

  # --- Response Parsing ---

  defp parse_response(body) when is_binary(body) do
    case Handbean.Agent.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} = err -> err
    end
  end

  defp parse_response(%{"type" => "message", "stop_reason" => reason} = resp)
       when reason in ["end_turn", "tool_use", "stop_sequence", "refusal"] do
    with {:ok, content_blocks} <- parse_content_blocks(resp["content"]),
         true <- reason != "tool_use" or Enum.any?(content_blocks, &(&1.type == "tool_use")) do
      message = %Message{
        role: :assistant,
        content: content_blocks
      }

      {:ok,
       %{
         stop_reason: parse_stop_reason(reason),
         messages: [message],
         usage: parse_usage(resp["usage"] || %{})
       }}
    else
      false -> {:error, "Anthropic response announced tool use but supplied none"}
      {:error, _} = error -> error
    end
  end

  defp parse_response(%{"type" => "error"} = resp) do
    error = resp["error"] || %{}
    {:error, "#{error["type"]}: #{error["message"]}"}
  end

  defp parse_response(_resp), do: {:error, "Anthropic response did not complete successfully"}

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("stop_sequence"), do: :end_turn
  defp parse_stop_reason("refusal"), do: :end_turn

  defp parse_content_blocks(blocks) when is_list(blocks) do
    if Enum.all?(blocks, &valid_content_block?/1),
      do: {:ok, Enum.map(blocks, &parse_content_block/1)},
      else: {:error, "Malformed Anthropic response content"}
  end

  defp parse_content_blocks(_blocks), do: {:error, "Malformed Anthropic response content"}

  defp valid_content_block?(%{"type" => "text", "text" => text}), do: is_binary(text)

  defp valid_content_block?(%{"type" => "thinking", "thinking" => thinking}),
    do: is_binary(thinking)

  defp valid_content_block?(%{"type" => type, "id" => id, "name" => name, "input" => input})
       when type in ["tool_use", "server_tool_use"] do
    is_binary(id) and id != "" and is_binary(name) and String.trim(name) != "" and is_map(input)
  end

  defp valid_content_block?(%{"type" => type})
       when type in ["text", "thinking", "tool_use", "server_tool_use"], do: false

  defp valid_content_block?(block), do: is_map(block)

  defp parse_content_block(%{"type" => "thinking", "thinking" => thinking} = block) do
    %{type: "thinking", thinking: thinking}
    |> maybe_put(:signature, block["signature"])
  end

  defp parse_content_block(%{"type" => "text", "text" => text}) do
    %{type: "text", text: text}
  end

  defp parse_content_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp parse_content_block(%{
         "type" => "server_tool_use",
         "id" => id,
         "name" => name,
         "input" => input
       }) do
    %{type: "server_tool_use", id: id, name: name, input: input}
  end

  defp parse_content_block(block) do
    # Unknown block type — preserve with string keys to avoid atom table
    # pollution from untrusted API responses. Only convert known keys.
    type = Map.get(block, "type", "unknown")
    %{type: type} |> Map.merge(Map.delete(block, "type"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp parse_usage(usage) do
    input = Map.get(usage, "input_tokens", 0)
    read = Map.get(usage, "cache_read_input_tokens", 0)
    write = Map.get(usage, "cache_creation_input_tokens", 0)

    %{
      input_tokens: input,
      total_input_tokens: input + read + write,
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_creation_input_tokens: write,
      cache_read_input_tokens: read
    }
  end

  defp parse_error(status, body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, %{"type" => "error", "error" => error}} ->
        "#{error["type"]}: #{error["message"]}"

      {:ok, %{"error" => error}} when is_map(error) ->
        "#{error["type"]}: #{error["message"]}"

      _ ->
        "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"type" => "error", "error" => error} ->
        "#{error["type"]}: #{error["message"]}"

      _ ->
        "HTTP #{status}: #{inspect(body)}"
    end
  end

  # ── Config normalization (Handbean adapter) ─────────────────────────────

  defp normalize_config(config) do
    config
    |> Map.put_new(:api_url, config[:base_url] || @default_api_url)
    |> Map.put_new(:receive_timeout, @default_receive_timeout)
    |> Map.put_new(:retry_count, @default_retry_count)
    |> Map.put_new(:cache, true)
  end

  defp default_req_options(config) do
    [receive_timeout: Map.get(config, :receive_timeout, @default_receive_timeout)]
  end

  # Transport replay is owned by Handbean.Agent.Turn + Provider.Retry.
  # A second retry here multiplies attempts after visible output may exist.
  defp request_with_retry(req_opts, _retry_count, config) do
    req_mod = Map.get(config, :req_module, Req)
    req_mod.request(req_opts)
  end
end
