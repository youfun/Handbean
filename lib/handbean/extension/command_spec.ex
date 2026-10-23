defmodule Handbean.Extension.CommandSpec do
  @moduledoc """
  Command metadata namespaced as `/ext:<extension>:<command>`.
  Runtime binding is validated against trusted compiled modules by Capabilities.
  """

  alias Handbean.Extension.{Diagnostic, Manifest}

  defstruct [:extension, :name, :description]
  @type t :: %__MODULE__{extension: String.t(), name: String.t(), description: String.t() | nil}

  @spec new(String.t(), String.t(), map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(_extension, "", _opts),
    do: {:error, %Diagnostic{type: :validation_error, message: "command name must not be empty"}}

  def new(extension, name, opts) do
    with :ok <- Manifest.validate_name(extension),
         :ok <- validate_name(name) do
      {:ok,
       %__MODULE__{
         extension: extension,
         name: "/ext:#{extension}:#{name}",
         description: Handbean.Utils.SafeMap.get_any(opts, :description, "description")
       }}
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z][a-z0-9_:-]*\z/, name), do: :ok, else: invalid_name()
  end

  defp validate_name(_), do: invalid_name()

  defp invalid_name,
    do: {:error, %Diagnostic{type: :validation_error, message: "invalid local command name"}}
end
