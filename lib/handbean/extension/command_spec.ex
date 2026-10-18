defmodule Handbean.Extension.CommandSpec do
  @moduledoc """
  Extension-declared command data structure.

  Commands are auto-prefixed with `/ext:`.
  Only validates and stores metadata. Does NOT connect to LiveView.
  """

  alias Handbean.Extension.Manifest
  alias Handbean.Extension.Diagnostic

  defstruct [:extension, :name, :description]

  @type t :: %__MODULE__{
          extension: String.t(),
          name: String.t(),
          description: String.t() | nil
        }

  @spec new(String.t(), String.t(), map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(_extension, "", _opts) do
    {:error, %Diagnostic{type: :validation_error, message: "command name must not be empty"}}
  end

  def new(extension, cmd_name, opts) do
    with :ok <- Manifest.validate_name(extension) do
      namespaced =
        if String.starts_with?(cmd_name, "/ext:") do
          cmd_name
        else
          "/ext:#{cmd_name}"
        end

      spec = %__MODULE__{
        extension: extension,
        name: namespaced,
        description: Handbean.Utils.SafeMap.get_any(opts, :description, "description")
      }

      {:ok, spec}
    end
  end
end
