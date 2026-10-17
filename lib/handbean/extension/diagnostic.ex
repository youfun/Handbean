defmodule Handbean.Extension.Diagnostic do
  @moduledoc """
  Represents a non-fatal error or warning encountered during extension loading or validation.

  Diagnostics are collected and returned alongside successful results
  rather than raising exceptions.
  """

  @type diag_type :: :parse_error | :validation_error | :warning | :collision

  defstruct [:type, :message, :details]

  @type t :: %__MODULE__{
          type: diag_type(),
          message: String.t(),
          details: term()
        }
end
