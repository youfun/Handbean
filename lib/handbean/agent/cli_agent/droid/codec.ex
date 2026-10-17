defmodule Handbean.Agent.CliAgent.Droid.Codec do
  @moduledoc """
  Factory stream JSON-RPC codec.

  Stdin is one request per line. Stdout is one response, server request, or
  notification per line. Nothing in this module is part of
  `Handbean.Agent.CliAgent`; callers outside Droid must not import it.
  """

  alias Handbean.JSON

  @protocol_version "1.221.0"
  @api_version "1.0.0"
  @jsonrpc "2.0"

  @type wire :: map()

  @doc "Request that starts a new Droid session in `cwd`."
  @spec initialize_session(String.t(), String.t(), keyword()) :: wire()
  def initialize_session(id, cwd, opts \\ []) when is_binary(id) and is_binary(cwd) do
    params =
      %{"machineId" => "handbean", "cwd" => cwd}
      |> put_if("sessionId", Keyword.get(opts, :session_id))

    request(id, "droid.initialize_session", params)
  end

  @doc "Request that resumes a saved Droid session. The saved session owns cwd."
  @spec load_session(String.t(), String.t()) :: wire()
  def load_session(id, session_id) when is_binary(id) and is_binary(session_id) do
    request(id, "droid.load_session", %{"sessionId" => session_id})
  end

  @doc "One user turn. The child process applies it to the active session."
  @spec add_user_message(String.t(), String.t()) :: wire()
  def add_user_message(id, text) when is_binary(id) and is_binary(text) do
    request(id, "droid.add_user_message", %{"text" => text})
  end

  @doc "Stop the current turn. Empty params; the process stays up."
  @spec interrupt_session(String.t()) :: wire()
  def interrupt_session(id) when is_binary(id) do
    request(id, "droid.interrupt_session", %{})
  end

  @doc "Sessionless model catalog. `includeDisabled` is sent only when asked."
  @spec list_models(String.t(), keyword()) :: wire()
  def list_models(id, opts \\ []) when is_binary(id) do
    params =
      if Keyword.get(opts, :include_disabled, false),
        do: %{"includeDisabled" => true},
        else: %{}

    request(id, "droid.list_models", params)
  end

  @doc """
  Mid-session model change.

  Applies on the next Droid turn, not inside a turn that is already running.
  """
  @spec update_session_settings(String.t(), keyword()) :: wire()
  def update_session_settings(id, opts) when is_binary(id) do
    params =
      %{}
      |> put_if("modelId", Keyword.get(opts, :model))
      |> put_if("reasoningEffort", Keyword.get(opts, :reasoning_effort))

    request(id, "droid.update_session_settings", params)
  end

  @doc "Answer a server-to-client request with the same id. Never a default approval."
  @spec respond(term(), map()) :: wire()
  def respond(id, result) when is_map(result) do
    envelope(id, %{"type" => "response", "result" => result})
  end

  @doc "Permission answer. `selectedOption` must be one of the options Droid offered."
  @spec permission_result(term()) :: map()
  def permission_result(selected) when is_binary(selected) do
    %{"selectedOption" => selected}
  end

  @doc "Ask-user answer. An empty answer list with `cancelled: true` declines the question."
  @spec ask_user_result([map()], boolean()) :: map()
  def ask_user_result(answers, cancelled \\ false)
      when is_list(answers) and is_boolean(cancelled) do
    %{"cancelled" => cancelled, "answers" => answers}
  end

  @doc "Encode one wire message as a stdin line."
  @spec encode_line(wire()) :: iodata()
  def encode_line(message) when is_map(message) do
    [JSON.encode!(message), "\n"]
  end

  @doc "Decode one stdout line. Non-JSON lines are ignored."
  @spec decode_line(String.t()) :: {:ok, wire()} | :ignore
  def decode_line(line) when is_binary(line) do
    line = String.trim(line)

    if line == "" do
      :ignore
    else
      case JSON.decode(line) do
        {:ok, %{} = message} -> {:ok, message}
        _ -> :ignore
      end
    end
  end

  @doc """
  Classify one decoded stdout object.

  Server requests are returned separately so the session can answer them.
  Notifications become normalized events. A working-state return to `idle`
  after a non-idle state completes the turn.
  """
  @spec classify(wire(), map()) :: {atom(), term(), map()}
  def classify(message, turn) when is_map(message) do
    method = message["method"]

    cond do
      request?(message, "droid.request_permission") ->
        {:server_request, {:permission, message}, turn}

      request?(message, "droid.ask_user") ->
        {:server_request, {:ask_user, message}, turn}

      response?(message) ->
        {:response, message, turn}

      method == "droid.session_notification" ->
        classify_notification(message, turn)

      true ->
        {:ignore, message, turn}
    end
  end

  @doc "Models from a `droid.list_models` result. Drops disabled entries."
  @spec models(map()) :: {:ok, [map()]} | {:error, :models_unavailable}
  def models(%{"result" => %{"models" => models}}) when is_list(models) do
    selectable =
      models
      |> Enum.filter(&(is_map(&1) and &1["disabled"] != true and is_binary(&1["id"])))
      |> Enum.map(&public_model/1)

    {:ok, selectable}
  end

  def models(_), do: {:error, :models_unavailable}

  @doc "Session id from initialize or load. Missing id is a protocol failure."
  @spec session_id(map()) :: {:ok, String.t()} | {:error, :protocol}
  def session_id(%{"result" => %{"sessionId" => id}}) when is_binary(id) and id != "",
    do: {:ok, id}

  def session_id(%{"error" => error}) when is_map(error),
    do: {:error, {:protocol, error_reason(error)}}

  def session_id(_), do: {:error, :protocol}

  @doc "Exec argv. Autonomy defaults to read-only; `--auto` is passed only when asked."
  @spec argv(keyword()) :: [String.t()]
  def argv(opts) do
    base = ["exec", "--input-format", "stream-jsonrpc", "--output-format", "stream-jsonrpc"]

    base
    |> maybe_auto(Keyword.get(opts, :auto))
    |> maybe_flag("-m", Keyword.get(opts, :model))
    |> maybe_flag("-r", Keyword.get(opts, :reasoning_effort))
    |> maybe_flag("--cwd", Keyword.get(opts, :cwd))
  end

  defp classify_notification(message, turn) do
    notification = get_in(message, ["params", "notification"]) || %{}

    case notification["type"] do
      "assistant_text_delta" ->
        text = notification["textDelta"] || ""
        {{:event, {:text_delta, text}}, text, turn}

      "tool_call" ->
        tool = tool_start(notification["toolUse"] || %{})
        {{:event, {:tool_start, tool}}, tool, turn}

      "tool_result" ->
        tool = tool_end(notification)
        {{:event, {:tool_end, tool}}, tool, turn}

      "session_token_usage_changed" ->
        usage = usage(notification["tokenUsage"] || %{})
        {{:event, {:usage, usage}}, usage, turn}

      "error" ->
        reason = notification["message"] || "droid error"
        {{:event, {:error, reason}}, reason, turn}

      "session_state_changed" ->
        classify_working_state(notification["newState"] || notification["state"], message, turn)

      "droid_working_state_changed" ->
        classify_working_state(notification["newState"], message, turn)

      _ ->
        {:ignore, message, turn}
    end
  end

  defp classify_working_state(state, _message, turn) when is_binary(state) and state != "idle" do
    {{:event, {:status, %{state: state}}}, state, %{turn | seen_work: true}}
  end

  defp classify_working_state("idle", message, %{seen_work: true} = turn) do
    done = %{
      stop_reason: :end_turn,
      session_id: turn.session_id || get_in(message, ["params", "sessionId"])
    }

    {{:event, {:turn_end, done}}, done, %{turn | seen_work: false, done: true}}
  end

  defp classify_working_state(_state, _message, turn), do: {:ignore, :idle, turn}

  defp tool_start(tool_use) do
    %{
      name: tool_use["title"] || tool_use["name"] || "unknown",
      id: tool_use["id"] || "tool",
      input: tool_use["input"] || %{}
    }
  end

  defp tool_end(notification) do
    %{
      id: notification["toolUseId"] || notification["id"] || "tool",
      output: render_output(notification["content"]),
      is_error: notification["isError"] == true
    }
  end

  defp usage(token_usage) do
    %{
      input_tokens: token_usage["inputTokens"],
      output_tokens: token_usage["outputTokens"],
      cache_creation_tokens: token_usage["cacheCreationTokens"],
      cache_read_tokens: token_usage["cacheReadTokens"],
      thinking_tokens: token_usage["thinkingTokens"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp public_model(model) do
    levels = model["supportedReasoningEfforts"] || []

    %{
      id: model["id"],
      display_name: model["displayName"] || model["id"],
      reasoning_levels: Enum.filter(levels, &is_binary/1)
    }
  end

  defp render_output(content) when is_binary(content), do: clean_terminal(content)

  defp render_output(content) when is_list(content) do
    content
    |> Enum.map_join("\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{"content" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      other -> inspect(other)
    end)
    |> clean_terminal()
  end

  defp render_output(nil), do: ""

  defp render_output(other), do: other |> inspect() |> clean_terminal()

  @max_rendered_output 4_000

  defp clean_terminal(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)/, "")
      |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
      |> String.replace("\r\n", "\n")
      |> String.replace(~r/^.*\r(?!\n)/m, "")
      |> String.replace("\r", "\n")

    if byte_size(cleaned) > @max_rendered_output do
      prefix = String.slice(cleaned, 0, @max_rendered_output)
      hidden_bytes = byte_size(cleaned) - byte_size(prefix)

      if hidden_bytes > 0 do
        prefix <> "\n... (#{hidden_bytes} bytes hidden)"
      else
        cleaned
      end
    else
      cleaned
    end
  end

  defp request?(message, method) do
    message["method"] == method and message["id"] != nil and message["type"] in ["request", nil]
  end

  defp response?(message) do
    message["type"] == "response" or
      ((is_map(message["result"]) or is_map(message["error"])) and message["id"] != nil and
         message["method"] == nil)
  end

  defp request(id, method, params) do
    envelope(id, %{"type" => "request", "method" => method, "params" => params})
  end

  defp envelope(id, extra) do
    Map.merge(
      %{
        "jsonrpc" => @jsonrpc,
        "factoryApiVersion" => @api_version,
        "factoryProtocolVersion" => @protocol_version,
        "id" => id
      },
      extra
    )
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp maybe_auto(argv, nil), do: argv
  defp maybe_auto(argv, level), do: argv ++ ["--auto", Atom.to_string(level)]

  defp maybe_flag(argv, _flag, nil), do: argv
  defp maybe_flag(argv, flag, value) when is_binary(value), do: argv ++ [flag, value]

  defp error_reason(%{"message" => message}) when is_binary(message), do: message
  defp error_reason(error), do: inspect(error)
end
