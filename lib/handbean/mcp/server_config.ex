defmodule Handbean.MCP.ServerConfig do
  @moduledoc """
  Normalized configuration for a single MCP server.

  Holds raw configuration fields and the runtime-resolved environment.
  """
  defstruct [
    :name,
    :command,
    args: [],
    env: %{},
    runtime_env: %{},
    disabled: false,
    cwd: nil,
    transport: "stdio",
    type: nil,
    url: nil,
    headers: %{},
    runtime_headers: %{},
    protocol_era: nil,
    runtime_capabilities: nil,
    oauth: nil,
    oauth_scope: nil,
    source: nil,
    exposure: "deferred",
    description: nil,
    raw: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          env: %{String.t() => String.t()},
          runtime_env: %{String.t() => String.t()},
          disabled: boolean(),
          cwd: String.t() | nil,
          transport: String.t(),
          type: String.t() | nil,
          url: String.t() | nil,
          headers: %{String.t() => String.t()},
          runtime_headers: %{String.t() => String.t()},
          protocol_era: :modern | :legacy | nil,
          runtime_capabilities: map() | nil,
          oauth: map() | nil,
          oauth_scope: keyword() | nil,
          source: String.t() | nil,
          exposure: String.t(),
          description: String.t() | nil,
          raw: map()
        }
end
