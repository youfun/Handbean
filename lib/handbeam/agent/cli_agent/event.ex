defmodule Handbeam.Agent.CliAgent.Event do
  @moduledoc """
  Normalized CLI-agent events.

  These tuples are the only events that cross the backend boundary. A
  backend's wire protocol, including Droid JSON-RPC, stays inside that
  backend's module.
  """

  @type text_delta :: {:text_delta, String.t()}
  @type tool_start ::
          {:tool_start,
           %{
             required(:name) => String.t(),
             required(:id) => String.t(),
             optional(:input) => map()
           }}
  @type tool_end ::
          {:tool_end,
           %{
             required(:id) => String.t(),
             optional(:output) => term(),
             optional(:is_error) => boolean()
           }}
  @type permission_request :: {:permission_request, map()}
  @type ask_user :: {:ask_user, map()}
  @type usage :: {:usage, map()}
  @type turn_end ::
          {:turn_end, %{optional(:stop_reason) => term(), optional(:session_id) => String.t()}}
  @type error :: {:error, term()}

  @type status :: {:status, %{optional(:state) => String.t() | atom()}}
  @type t ::
          text_delta()
          | tool_start()
          | tool_end()
          | permission_request()
          | ask_user()
          | usage()
          | status()
          | turn_end()
          | error()

  @doc "Events a caller may pattern-match. Backend wire tags are not in this list."
  @spec tags() :: [atom()]
  def tags do
    [
      :text_delta,
      :tool_start,
      :tool_end,
      :permission_request,
      :ask_user,
      :usage,
      :status,
      :turn_end,
      :error
    ]
  end

  @doc "Whether `event` is a normalized tuple and contains no backend wire keys."
  @spec normalized?(term()) :: boolean()
  def normalized?({tag, payload}) when tag in [:text_delta, :error] do
    is_binary(payload) or is_atom(payload) or is_map(payload)
  end

  def normalized?({tag, payload})
      when tag in [:tool_start, :tool_end, :usage, :status, :turn_end] do
    is_map(payload) and not wire?(payload)
  end

  def normalized?({tag, payload}) when tag in [:permission_request, :ask_user] do
    is_map(payload) and not wire?(payload)
  end

  def normalized?(_), do: false

  @doc "Whether a map still carries a backend protocol envelope."
  @spec wire?(map()) :: boolean()
  def wire?(payload) when is_map(payload) do
    keys = Map.keys(payload)

    Enum.any?(keys, &(&1 in ["jsonrpc", "method", "factoryProtocolVersion", :jsonrpc, :method])) or
      Enum.any?(keys, &wire_key?/1)
  end

  def wire?(_), do: false

  defp wire_key?(key) when is_binary(key) do
    String.starts_with?(key, "droid.") or
      key in ["textDelta", "toolUse", "newState", "selectedOption"]
  end

  defp wire_key?(key) when is_atom(key) do
    key |> Atom.to_string() |> wire_key?()
  end

  defp wire_key?(_), do: false
end
