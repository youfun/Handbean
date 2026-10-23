defmodule Handbean.Extension.ProviderSpec do
  @moduledoc """
  Extension-declared model provider metadata.

  Provider identifiers are namespaced as `ext:<extension>:<provider>`.
  """

  alias Handbean.Extension.Manifest
  alias Handbean.Extension.Diagnostic

  defstruct [:extension, :name, :base_url, :api, :api_key_env, models: []]

  @type t :: %__MODULE__{
          extension: String.t(),
          name: String.t(),
          base_url: String.t() | nil,
          api: String.t() | nil,
          api_key_env: String.t() | nil,
          models: [map()]
        }

  @spec new(String.t(), String.t(), map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(_extension, "", _opts) do
    {:error, %Diagnostic{type: :validation_error, message: "provider name must not be empty"}}
  end

  def new(extension, provider_name, opts) do
    with :ok <- Manifest.validate_name(extension),
         :ok <- validate_name(provider_name) do
      spec = %__MODULE__{
        extension: extension,
        name: "ext:#{extension}:#{provider_name}",
        base_url: Handbean.Utils.SafeMap.get_any(opts, :base_url, "base_url"),
        api: Handbean.Utils.SafeMap.get_any(opts, :api, "api"),
        api_key_env: Handbean.Utils.SafeMap.get_any(opts, :api_key_env, "api_key_env"),
        models: Handbean.Utils.SafeMap.get_any(opts, :models, "models") || []
      }

      {:ok, spec}
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, name),
      do: :ok,
      else: {:error, %Diagnostic{type: :validation_error, message: "invalid local provider name"}}
  end

  defp validate_name(_),
    do: {:error, %Diagnostic{type: :validation_error, message: "invalid local provider name"}}
end
