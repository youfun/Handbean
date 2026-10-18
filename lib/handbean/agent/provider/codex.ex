defmodule Handbean.Agent.Provider.Codex do
  @moduledoc """
  Stateless SSE Responses transport for a personal ChatGPT/Codex subscription.

  Handbean owns tools, approvals and the turn loop. Every request sends history;
  encrypted reasoning is retained in opaque content blocks, not server sessions.
  This backend is distinct from the public, API-key-billed OpenAI Responses API.
  """

  @behaviour Handbean.Agent.Provider

  alias Handbean.Agent.Auth.{CodexCredential, CodexOAuth}
  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.{OpenAI, SSE}

  @endpoint "https://chatgpt.com/backend-api/codex/responses"
  # One replay before any model output. A dropped header is not a completed
  # response, and replaying after a tool call would execute the tool twice.
  @transport_attempts 2

  @impl true
  def complete(messages, tool_defs, config),
    do: stream(messages, tool_defs, config, fn _ -> :ok end)

  @impl true
  def stream(messages, tool_defs, config, on_chunk) do
    with {:ok, auth} <- resolve_auth(config) do
      body = request_body(messages, tool_defs, config, auth)
      request(body, auth, config, on_chunk, 1)
    end
  end

  defp request(body, auth, config, on_chunk, attempt) do
    state = :counters.new(1, [:atomics])
    initial = %{buffer: "", output: %{}, phases: %{}, response: nil, error: nil}
    req = Map.get(config, :req_module, Req)

    options =
      Map.get(config, :req_options, [])
      |> Keyword.merge(
        url: @endpoint,
        method: :post,
        headers: headers(auth, config),
        body: Handbean.JSON.encode!(body),
        into: stream_handler(initial, on_chunk, state),
        retry: false,
        redirect: false,
        receive_timeout: Map.get(config, :receive_timeout, 180_000),
        connect_options: [timeout: Map.get(config, :connect_timeout, 30_000)]
      )

    case req.request(options) do
      {:ok, %{status: 200} = response} ->
        finish(Map.get(response.private, :codex_sse, initial), auth, config)

      {:ok, %{status: 401}} ->
        {:error, "ChatGPT authorization rejected. Sign in again."}

      {:ok, %{status: 403}} ->
        {:error, "ChatGPT account does not have access to this Codex model."}

      {:ok, %{status: 429}} ->
        {:error,
         "ChatGPT Codex usage limit reached. Check your subscription usage and retry later."}

      {:ok, %{status: status} = response} ->
        {:error, http_error(status, response_error(response))}

      {:error, exception} ->
        replay_or_fail(state, exception, body, auth, config, on_chunk, attempt)
    end
  end

  # A failure before the first SSE byte is not a completed response. Once any
  # event has been emitted the request is not idempotent, so it is not replayed.
  defp replay_or_fail(state, exception, body, auth, config, on_chunk, attempt) do
    if attempt < @transport_attempts and :counters.get(state, 1) == 0 do
      request(body, auth, config, on_chunk, attempt + 1)
    else
      {:error,
       "Codex connection ended without a complete response (#{transport_reason(exception)}). Request was replayed once."}
    end
  end

  @doc false
  def headers(auth, config \\ %{}) do
    session_id = session_id(config)

    [
      {"authorization", "Bearer #{auth.api_key}"},
      {"chatgpt-account-id", auth.account_id},
      {"originator", "pi"},
      {"user-agent", user_agent()},
      {"openai-beta", "responses=experimental"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"session-id", session_id},
      {"x-client-request-id", session_id}
    ]
  end

  defp session_id(config) do
    case config[:session_id] do
      id when is_binary(id) and id != "" -> id
      _ -> "handbean"
    end
  end

  defp user_agent do
    os = :os.type() |> elem(1) |> to_string()
    "pi (#{os})"
  end

  defp resolve_auth(%{auth_type: :oauth} = config) do
    with {:ok, auth} <-
           CodexCredential.resolve_transport_key(config[:provider_key] || "openai_codex") do
      if config[:auth_generation] && config.auth_generation != auth.auth_generation do
        {:error, "ChatGPT account changed during this run. Start a new run."}
      else
        {:ok, auth}
      end
    end
  end

  defp resolve_auth(config) do
    with {:ok, account_id} <- CodexOAuth.account_id(config[:api_key]) do
      {:ok, %{api_key: config.api_key, account_id: account_id}}
    end
  end

  defp request_body(messages, tool_defs, config, auth) do
    body = %{
      "model" => config.model,
      "instructions" => config[:system_prompt] || "You are a helpful coding assistant.",
      "input" => Enum.flat_map(messages, &input_items(&1, auth.account_id, config.model)),
      "tools" => Enum.map(tool_defs, &format_tool_def/1),
      "store" => false,
      "stream" => true,
      "text" => %{"verbosity" => "low"},
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => session_id(config),
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    }

    body =
      case config[:reasoning] do
        reasoning when is_map(reasoning) ->
          Map.put(body, "reasoning", reasoning_options(reasoning))

        _ ->
          body
      end

    if body["tools"] == [], do: Map.delete(body, "tools"), else: body
  end

  # Pi sends strict: null. A missing field matches that; `false` is rejected by
  # newer Codex models and closes the stream before any event.
  defp format_tool_def(tool) do
    tool
    |> OpenAI.format_tool_def()
    |> Map.delete("strict")
  end

  defp reasoning_options(reasoning) do
    reasoning
    |> Handbean.Agent.Provider.stringify_keys()
    |> Map.put_new("summary", "auto")
  end

  defp http_error(status, nil), do: "Codex request failed (HTTP #{status})."

  defp http_error(status, message),
    do: "Codex request failed (HTTP #{status}): #{sanitize_error(message)}"

  defp response_error(%{body: body}) when is_binary(body) and body != "", do: error_message(body)
  defp response_error(%{body: body}) when is_map(body) and body != %{}, do: error_message(body)

  defp response_error(%{private: private}) when is_map(private) do
    case private[:codex_sse] do
      %{buffer: buffer} when is_binary(buffer) -> error_message(buffer)
      _ -> nil
    end
  end

  defp response_error(_), do: nil

  defp error_message(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, decoded} -> error_message(decoded)
      _ -> nil
    end
  end

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(_), do: nil

  defp sanitize_error(message) do
    message
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 180)
  end

  defp transport_reason(%{reason: reason}), do: transport_reason(reason)

  defp transport_reason(reason) do
    reason
    |> inspect()
    |> sanitize_error()
    |> String.slice(0, 80)
  end

  defp input_items(%Message{role: :assistant, content: blocks} = message, account_id, model)
       when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %{type: type, account_id: ^account_id, model: ^model, item: item}
      when type in ["codex_reasoning", "responses_reasoning"] ->
        [item]

      %{
        "type" => type,
        "account_id" => ^account_id,
        "model" => ^model,
        "item" => item
      }
      when type in ["codex_reasoning", "responses_reasoning"] ->
        [item]

      %{type: type} when type in ["codex_reasoning", "responses_reasoning"] ->
        []

      %{"type" => type} when type in ["codex_reasoning", "responses_reasoning"] ->
        []

      %{type: "text"} = block ->
        [assistant_message_item(block)]

      block ->
        OpenAI.build_input_items([%{message | content: [block]}], %{})
    end)
  end

  defp input_items(message, _account_id, _model), do: OpenAI.build_input_items([message], %{})

  # Pi replays each assistant message as a completed output item, including
  # phase. A bare `{role, content}` string is not a Codex message item and is
  # dropped by newer subscription models, so the next turn looks empty.
  defp assistant_message_item(%{type: "text", text: text} = block) do
    item = %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}],
      "status" => "completed",
      "id" => message_item_id(block)
    }

    case block[:phase] do
      phase when phase in ["commentary", "final_answer"] -> Map.put(item, "phase", phase)
      _ -> item
    end
  end

  defp message_item_id(%{id: id}) when is_binary(id) and id != "" do
    # Transcript IDs (msg-assistant-...) are not Codex message item IDs.
    # Preserve native IDs; map local IDs deterministically at the wire boundary.
    if byte_size(id) <= 64 and Regex.match?(~r/\Amsg_[A-Za-z0-9_-]+\z/, id),
      do: id,
      else: "msg_" <> short_hash(id)
  end

  defp message_item_id(_block),
    do: "msg_" <> short_hash(Base.encode16(:crypto.strong_rand_bytes(8)))

  defp short_hash(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp streamed_phase(acc, index) do
    case acc.phases[index] do
      %{"phase" => "final_answer"} -> "final_answer"
      _ -> "commentary"
    end
  end

  defp stream_handler(initial, on_chunk, state) do
    fn {:data, chunk}, {req, response} ->
      if response.status == 200 do
        :counters.add(state, 1, 1)
        acc = Map.get(response.private, :codex_sse, initial)
        {events, buffer} = SSE.process_chunk(acc.buffer, chunk)
        acc = Enum.reduce(events, %{acc | buffer: buffer}, &handle_event(&1, &2, on_chunk))
        {:cont, {req, put_in(response.private[:codex_sse], acc)}}
      else
        # Keep only the bounded error body. Authorization echoes must not survive.
        acc = Map.get(response.private, :codex_sse, initial)
        buffer = String.slice(acc.buffer <> to_string(chunk), 0, 2048)
        {:cont, {req, put_in(response.private[:codex_sse], %{acc | buffer: buffer})}}
      end
    end
  end

  defp handle_event(_event, %{error: error} = acc, _on_chunk) when not is_nil(error), do: acc
  defp handle_event(%{data: "[DONE]"}, acc, _on_chunk), do: acc

  defp handle_event(%{data: data}, acc, on_chunk) do
    case Handbean.JSON.decode(data) do
      {:ok, %{"type" => type} = event} -> process_event(type, event, acc, on_chunk)
      _ -> %{acc | error: "Invalid Codex stream event"}
    end
  end

  # Live chunks are commentary until a message item is known to be the final
  # answer. Replaying the terminal item would append the same text twice.
  defp process_event(
         "response.output_text.delta",
         %{"delta" => text, "output_index" => index},
         acc,
         on_chunk
       )
       when is_binary(text) and is_integer(index) do
    phase = streamed_phase(acc, index)
    on_chunk.(%{text: text, phase: phase, output_index: index})
    acc
  end

  defp process_event("response.output_text.delta", %{"delta" => text}, acc, on_chunk)
       when is_binary(text) do
    on_chunk.(text)
    acc
  end

  defp process_event(
         "response.output_item.added",
         %{"output_index" => index, "item" => item},
         acc,
         _
       )
       when is_integer(index) and is_map(item),
       do: %{acc | phases: Map.put(acc.phases, index, item)}

  defp process_event(
         "response.output_item.done",
         %{"output_index" => index, "item" => item},
         acc,
         _
       )
       when is_integer(index) and is_map(item) do
    %{acc | output: Map.put(acc.output, index, item), phases: Map.put(acc.phases, index, item)}
  end

  defp process_event(type, %{"response" => response}, acc, _)
       when type in ["response.completed", "response.done"] and is_map(response),
       do: %{acc | response: response}

  defp process_event(type, _event, acc, _) when type in ["response.failed", "error"],
    do: %{acc | error: "Codex reported a failed response. No tools were executed."}

  defp process_event("response.incomplete", _event, acc, _),
    do: %{acc | error: "Codex response was incomplete. No tools were executed."}

  defp process_event(_type, _event, acc, _), do: acc

  defp finish(%{error: error}, _auth, _config) when not is_nil(error), do: {:error, error}

  defp finish(%{response: nil}, _auth, _config),
    do: {:error, "Codex stream ended before its terminal response. No tools were executed."}

  defp finish(%{response: response, output: streamed}, auth, config) do
    # Codex can complete with output: [] after delivering full output_item.done
    # events. Preserve provider indices so reasoning or tool items cannot
    # renumber the final text during stream reconciliation.
    {output, indexed_output} = indexed_output(response["output"], streamed)

    with :ok <- validate_output(response, output),
         {:ok, parsed} <- OpenAI.parse_response(Map.put(response, "output", output)),
         {:ok, blocks} <- output_blocks(indexed_output, auth.account_id, config.model) do
      usage = response["usage"] || %{}

      {:ok,
       %{
         parsed
         | messages: [Message.assistant_blocks(blocks)],
           provider_state: %{},
           usage:
             Map.put(
               parsed.usage,
               :reasoning_tokens,
               get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0
             )
       }}
    end
  end

  defp indexed_output(output, streamed) when output in [nil, []] do
    indexed = Enum.sort_by(streamed, &elem(&1, 0))
    {Enum.map(indexed, &elem(&1, 1)), indexed}
  end

  defp indexed_output(output, _streamed) when is_list(output) do
    indexed = output |> Enum.with_index() |> Enum.map(fn {item, index} -> {index, item} end)
    {output, indexed}
  end

  defp indexed_output(output, _streamed), do: {output, []}

  defp validate_output(%{"status" => status}, _)
       when status in ["failed", "incomplete", "cancelled"],
       do: {:error, "Codex response did not complete. No tools were executed."}

  defp validate_output(_, output) when is_list(output) do
    if Enum.all?(output, &valid_item?/1),
      do: :ok,
      else: {:error, "Invalid Codex output item. No tools were executed."}
  end

  defp validate_output(_, _), do: {:error, "Invalid Codex response output"}

  defp valid_item?(%{
         "type" => "function_call",
         "call_id" => id,
         "name" => name,
         "arguments" => args
       })
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_binary(args) do
    case Handbean.JSON.decode(args) do
      {:ok, input} when is_map(input) -> true
      _ -> false
    end
  end

  defp valid_item?(%{"type" => "function_call"}), do: false
  defp valid_item?(%{"type" => type}) when type in ["message", "reasoning"], do: true
  defp valid_item?(_), do: false

  defp output_blocks(indexed_output, account_id, model) do
    result =
      Enum.reduce_while(indexed_output, {:ok, []}, fn
        {_output_index, %{"type" => "reasoning", "encrypted_content" => encrypted} = item},
        {:ok, acc}
        when is_binary(encrypted) ->
          block = %{
            type: "responses_reasoning",
            account_id: account_id,
            model: model,
            item: Map.take(item, ["type", "id", "summary", "encrypted_content"])
          }

          {:cont, {:ok, [[block] | acc]}}

        {output_index, %{"type" => "message"} = item}, {:ok, acc} ->
          case message_blocks(item, output_index) do
            {:ok, blocks} -> {:cont, {:ok, [blocks | acc]}}
            error -> {:halt, error}
          end

        {_output_index, item}, {:ok, acc} ->
          case OpenAI.parse_response(%{"output" => [item]}) do
            {:ok, %{messages: [message]}} -> {:cont, {:ok, [message.content | acc]}}
            error -> {:halt, error}
          end
      end)

    case result do
      {:ok, blocks} -> {:ok, blocks |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp message_blocks(%{"type" => "message"} = item, output_index) do
    case OpenAI.parse_response(%{"output" => [item]}) do
      {:ok, %{messages: [message]}} ->
        {:ok, Enum.map(message.content, &put_message_identity(&1, item, output_index))}

      error ->
        error
    end
  end

  defp put_message_identity(%{type: "text"} = block, item, output_index) do
    block
    |> maybe_put_block(:id, item["id"])
    |> maybe_put_block(:phase, item["phase"])
    |> Map.put(:output_index, output_index)
  end

  defp put_message_identity(block, _item, _output_index), do: block

  defp maybe_put_block(block, _key, value) when value in [nil, ""], do: block
  defp maybe_put_block(block, key, value), do: Map.put(block, key, value)
end
