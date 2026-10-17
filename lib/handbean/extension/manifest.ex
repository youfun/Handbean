defmodule Handbean.Extension.Manifest do
  @moduledoc """
  Parses and validates extension JSON manifests.

  Does NOT execute any code. Only parses metadata.
  """

  alias Handbean.Extension.Diagnostic

  defstruct [
    :name,
    :version,
    :description,
    :entry,
    enabled: true,
    permissions: %{},
    hooks: [],
    tools: [],
    commands: [],
    providers: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t() | nil,
          description: String.t() | nil,
          entry: String.t() | nil,
          enabled: boolean(),
          permissions: map(),
          hooks: [String.t()],
          tools: [map()],
          commands: [map()],
          providers: [map()],
          metadata: map()
        }

  @valid_name_re ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  @default_permissions %{"network" => [], "filesystem" => "none", "tools" => []}

  @doc """
  Parses a JSON string into a validated manifest struct.

  Returns `{:ok, manifest}` on success or `{:error, diagnostic}` on failure.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def from_json(json) when is_binary(json) do
    with {:ok, data} <- parse_json(json),
         :ok <- validate_object(data),
         {:ok, name} <- extract_name(data),
         :ok <- validate_name(name) do
      manifest = build_manifest(data, name)
      {:ok, manifest}
    else
      {:error, %Diagnostic{} = diagnostic} -> {:error, diagnostic}
    end
  end

  @doc """
  Validates an extension name.

  Rules:
  - lower-case letters, numbers, hyphen only
  - cannot be empty
  - cannot start or end with hyphen
  - cannot contain consecutive hyphens
  """
  @spec validate_name(String.t()) :: :ok | {:error, Diagnostic.t()}
  def validate_name(name) when is_binary(name) do
    if String.match?(name, @valid_name_re) do
      :ok
    else
      {:error,
       %Diagnostic{
         type: :validation_error,
         message:
           "invalid extension name: #{inspect(name)}. " <>
             "Name must contain only lowercase letters, numbers, and single hyphens " <>
             "(cannot start/end with hyphen, cannot have consecutive hyphens)."
       }}
    end
  end

  # ── Private helpers ──

  defp parse_json(json) do
    case Handbean.JSON.decode(json) do
      {:ok, data} ->
        {:ok, data}

      {:error, error} ->
        {:error, %Diagnostic{type: :parse_error, message: "JSON parse error: #{inspect(error)}"}}
    end
  end

  defp validate_object(data) when is_map(data) and not is_struct(data), do: :ok

  defp validate_object(_),
    do: {:error, %Diagnostic{type: :validation_error, message: "manifest must be a JSON object"}}

  defp extract_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}

  defp extract_name(%{"name" => _}),
    do:
      {:error,
       %Diagnostic{
         type: :validation_error,
         message: "extension name is required and must be a non-empty string"
       }}

  defp extract_name(_),
    do:
      {:error,
       %Diagnostic{
         type: :validation_error,
         message: "extension name is required and must be a non-empty string"
       }}

  defp build_manifest(data, name) do
    known_fields =
      ~w(name version description entry enabled permissions hooks tools commands providers)

    metadata =
      data
      |> Map.drop(known_fields)
      |> Map.new()

    %__MODULE__{
      name: name,
      version: data["version"],
      description: data["description"],
      entry: data["entry"],
      enabled: Map.get(data, "enabled", true),
      permissions: merge_permissions(Map.get(data, "permissions", %{})),
      hooks: parse_list_field(data, "hooks"),
      tools: parse_list_field(data, "tools"),
      commands: parse_list_field(data, "commands"),
      providers: parse_list_field(data, "providers"),
      metadata: metadata
    }
  end

  defp merge_permissions(%{} = provided) do
    Map.merge(@default_permissions, provided)
  end

  defp merge_permissions(_), do: @default_permissions

  defp parse_list_field(data, field) do
    case Map.get(data, field) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
