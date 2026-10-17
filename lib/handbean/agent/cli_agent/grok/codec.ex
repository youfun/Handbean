defmodule Handbean.Agent.CliAgent.Grok.Codec do
  @moduledoc """
  Grok ACP codec.

  `grok agent stdio` speaks Agent Client Protocol over newline-delimited
  JSON-RPC. Nothing here is part of `Handbean.Agent.CliAgent`.
  """

  alias Handbean.JSON

  @type wire :: map()

  @spec argv(keyword()) :: [String.t()]
  def argv(opts) do
    args = ["agent", "--no-leader"]

    args
    |> maybe_flag("--model", Keyword.get(opts, :model))
    |> maybe_flag("--reasoning-effort", Keyword.get(opts, :reasoning_effort))
    |> Kernel.++(["stdio"])
  end

  @spec initialize(term()) :: wire()
  def initialize(id) do
    request(id, "initialize", %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      },
      "clientInfo" => %{"name" => "handbean", "version" => "0.1.0"}
    })
  end

  @spec new_session(term(), String.t()) :: wire()
  def new_session(id, cwd) when is_binary(cwd) do
    request(id, "session/new", %{"cwd" => cwd, "mcpServers" => []})
  end

  @spec load_session(term(), String.t(), String.t()) :: wire()
  def load_session(id, session_id, cwd) when is_binary(session_id) and is_binary(cwd) do
    request(id, "session/load", %{"sessionId" => session_id, "cwd" => cwd, "mcpServers" => []})
  end

  @spec prompt(term(), String.t(), String.t()) :: wire()
  def prompt(id, session_id, text) when is_binary(session_id) and is_binary(text) do
    request(id, "session/prompt", %{
      "sessionId" => session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    })
  end

  @spec cancel(String.t()) :: wire()
  def cancel(session_id) when is_binary(session_id) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/cancel",
      "params" => %{"sessionId" => session_id}
    }
  end

  @spec permission_response(term(), String.t()) :: wire()
  def permission_response(id, option_id) when is_binary(option_id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
    }
  end

  @spec permission_cancel(term()) :: wire()
  def permission_cancel(id) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{"outcome" => %{"outcome" => "cancelled"}}}
  end

  @spec encode_line(wire()) :: iodata()
  def encode_line(message) when is_map(message), do: [JSON.encode!(message), "\n"]

  @spec decode_line(String.t()) :: {:ok, wire()} | :ignore
  def decode_line(line) when is_binary(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        :ignore

      String.starts_with?(line, "You are logged in") ->
        :ignore

      true ->
        case JSON.decode(line) do
          {:ok, %{} = message} -> {:ok, message}
          _ -> :ignore
        end
    end
  end

  @spec session_id(map()) :: {:ok, String.t()} | {:error, term()}
  def session_id(%{"result" => %{"sessionId" => id}}) when is_binary(id) and id != "",
    do: {:ok, id}

  def session_id(%{"error" => error}) when is_map(error),
    do: {:error, {:protocol, error_message(error)}}

  def session_id(_), do: {:error, :protocol}

  @spec stop_reason(map()) :: {:ok, atom()} | :pending | {:error, term()}
  def stop_reason(%{"result" => %{"stopReason" => reason}}) when is_binary(reason) do
    {:ok, stop_atom(reason)}
  end

  def stop_reason(%{"error" => error}) when is_map(error),
    do: {:error, {:protocol, error_message(error)}}

  def stop_reason(_), do: :pending

  @doc """
  Classify one stdout object.

  ACP notifications become normalized events. `session/request_permission`
  is a server request the session must answer. Non-ACP notices are ignored.
  """
  @spec classify(wire()) ::
          {:event, term()} | {:server_request, map()} | {:response, wire()} | :ignore
  def classify(message) when is_map(message) do
    cond do
      permission_request?(message) ->
        {:server_request, permission(message)}

      response?(message) ->
        {:response, message}

      message["method"] == "session/update" ->
        classify_update(get_in(message, ["params", "update"]) || %{})

      true ->
        :ignore
    end
  end

  @spec models_from_text(String.t()) :: {:ok, [map()]} | {:error, :models_unavailable}
  def models_from_text(text) when is_binary(text) do
    models =
      text
      |> String.split("\n")
      |> Enum.flat_map(&model_line/1)

    if models == [], do: {:error, :models_unavailable}, else: {:ok, models}
  end

  defp classify_update(update) do
    case update["sessionUpdate"] do
      "agent_message_chunk" ->
        text = get_in(update, ["content", "text"]) || ""
        if text == "", do: :ignore, else: {:event, {:text_delta, text}}

      "tool_call" ->
        {:event, {:tool_start, tool(update)}}

      "tool_call_update" ->
        {:event, {:tool_end, tool_end(update)}}

      "usage_update" ->
        {:event, {:usage, Map.drop(update, ["sessionUpdate"])}}

      _ ->
        :ignore
    end
  end

  defp permission_request?(message) do
    message["method"] == "session/request_permission" and message["id"] != nil
  end

  defp permission(message) do
    params = message["params"] || %{}

    %{
      id: message["id"],
      kind: :permission,
      title: params["title"] || "Grok permission",
      options:
        Enum.map(params["options"] || [], fn option ->
          %{
            "value" => option["optionId"],
            "label" => option["name"] || option["kind"] || option["optionId"]
          }
        end)
    }
  end

  defp tool(update) do
    %{
      name: update["title"] || update["toolCallId"] || "tool",
      id: to_string(update["toolCallId"] || update["title"] || "tool"),
      input: if(is_map(update["rawInput"]), do: update["rawInput"], else: %{})
    }
  end

  defp tool_end(update) do
    %{
      id: to_string(update["toolCallId"] || ""),
      output: update["rawOutput"] || update["content"],
      is_error: update["status"] in ["failed", "error"]
    }
  end

  defp response?(message) do
    message["id"] != nil and (is_map(message["result"]) or is_map(message["error"])) and
      message["method"] == nil
  end

  defp request(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp model_line(line) do
    case Regex.run(~r/^\s*[*+-]\s+(\S+)/, line) do
      [_, id] ->
        [%{id: id, display_name: id, reasoning_levels: []}]

      _ ->
        case Regex.run(~r/^Default model:\s+(\S+)/, line) do
          [_, id] -> [%{id: id, display_name: id, reasoning_levels: []}]
          _ -> []
        end
    end
  end

  defp stop_atom("end_turn"), do: :end_turn
  defp stop_atom("max_tokens"), do: :max_tokens
  defp stop_atom("cancelled"), do: :cancelled
  defp stop_atom(other), do: other

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)

  defp maybe_flag(argv, _flag, nil), do: argv
  defp maybe_flag(argv, flag, value) when is_binary(value), do: argv ++ [flag, value]
end
