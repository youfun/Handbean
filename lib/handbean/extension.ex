defmodule Handbean.Extension do
  @moduledoc """
  Extension struct representing a loaded (but not executed) extension.

  An extension is a "container of registrable capabilities."
  It holds hooks, tools, commands, and providers declared in its manifest.
  """

  alias Handbean.Extension.Manifest
  alias Handbean.Extension.Diagnostic

  defstruct [
    :name,
    :version,
    :description,
    :root,
    :entry,
    :scope,
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
          root: String.t(),
          entry: String.t() | nil,
          scope: :user | {:project, String.t()} | nil,
          enabled: boolean(),
          permissions: map(),
          hooks: [String.t()],
          tools: [map()],
          commands: [map()],
          providers: [map()],
          metadata: map()
        }

  @doc """
  Build an Extension struct from a validated %Manifest{} and a root directory.
  """
  @spec new(Manifest.t(), String.t()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(%Manifest{} = manifest, root) do
    with :ok <- validate_root(root),
         {:ok, entry} <- resolve_entry(manifest.entry, root) do
      ext = %__MODULE__{
        name: manifest.name,
        version: manifest.version,
        description: manifest.description,
        root: root,
        entry: entry,
        enabled: manifest.enabled,
        permissions: manifest.permissions,
        hooks: manifest.hooks,
        tools: manifest.tools,
        commands: manifest.commands,
        providers: manifest.providers,
        metadata: manifest.metadata
      }

      {:ok, ext}
    end
  end

  @doc "Returns true if the extension is active (enabled)."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{enabled: enabled}), do: enabled

  defp validate_root(root) when is_binary(root) do
    if Path.type(root) == :absolute do
      :ok
    else
      {:error,
       %Diagnostic{
         type: :validation_error,
         message: "extension root must be an absolute path, got: #{inspect(root)}"
       }}
    end
  end

  defp validate_root(root) do
    {:error,
     %Diagnostic{
       type: :validation_error,
       message: "extension root must be an absolute path, got: #{inspect(root)}"
     }}
  end

  defp resolve_entry(nil, _root), do: {:ok, nil}

  defp resolve_entry(entry, root) when is_binary(entry) do
    resolved = Path.expand(entry, root)

    if resolved == root or String.starts_with?(resolved, root <> "/") do
      {:ok, resolved}
    else
      {:error,
       %Diagnostic{
         type: :validation_error,
         message:
           "extension entry path resolves outside root: #{inspect(entry)} -> #{resolved} (root: #{root})"
       }}
    end
  end

  defp resolve_entry(entry, _root) do
    {:error,
     %Diagnostic{
       type: :validation_error,
       message: "extension entry must be a string when present, got: #{inspect(entry)}"
     }}
  end
end
