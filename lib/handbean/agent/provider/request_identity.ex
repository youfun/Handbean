defmodule Handbean.Agent.Provider.RequestIdentity do
  @moduledoc """
  Stable client identity headers for subscription APIs.

  OpenCode Go asks third-party coding agents to send their own user agent and
  a conversation-scoped `x-opencode-session` header. Ollama Cloud accepts the
  same user agent on its OpenAI-compatible endpoint.
  """

  @user_agent "Handbean/0.2.1"

  @doc "User-Agent Handbean sends instead of a generic HTTP client name."
  @spec user_agent() :: String.t()
  def user_agent, do: @user_agent

  @doc """
  Headers for one provider request.

  `x-opencode-session` is only attached when the caller asks for it and the
  turn has a conversation id. A missing id is omitted rather than invented.
  """
  @spec headers(map(), keyword()) :: [{String.t(), String.t()}]
  def headers(config, opts \\ []) when is_map(config) do
    [user_agent_header(config)] ++ session_header(config, opts)
  end

  defp user_agent_header(config) do
    {"user-agent", Map.get(config, :user_agent) || @user_agent}
  end

  defp session_header(config, opts) do
    if Keyword.get(opts, :session, false) do
      case conversation_id(config) do
        id when is_binary(id) and id != "" -> [{"x-opencode-session", id}]
        _ -> []
      end
    else
      []
    end
  end

  defp conversation_id(config) do
    Map.get(config, :conversation_id) || Map.get(config, :session_id)
  end
end
