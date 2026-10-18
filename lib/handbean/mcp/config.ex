defmodule Handbean.MCP.Config do
  @moduledoc """
  Top-level result of MCP configuration loading.

  Contains merged and validated server configs plus diagnostics.
  """
  defstruct servers: %{}, diagnostics: []

  @type t :: %__MODULE__{
          servers: %{String.t() => Handbean.MCP.ServerConfig.t()},
          diagnostics: [Handbean.MCP.Diagnostic.t()]
        }
end
