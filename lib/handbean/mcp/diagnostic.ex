defmodule Handbean.MCP.Diagnostic do
  @moduledoc """
  A diagnostic message produced during MCP configuration loading.

  Diagnostics must never contain sensitive values such as resolved
  environment variables, tokens, or secrets.
  """
  defstruct [:type, :message, :source, :server, details: %{}]

  @type type :: :error | :warning

  @type t :: %__MODULE__{
          type: type(),
          message: String.t(),
          source: String.t() | nil,
          server: String.t() | nil,
          details: map()
        }
end
