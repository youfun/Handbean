defmodule Handbean.Skills.Skill do
  @moduledoc """
  Skill data structure.

  Represents a discovered skill with its metadata, frontmatter,
  and file location. Does NOT include the body/content of the
  SKILL.md file.
  """

  @enforce_keys [:name, :description, :location, :base_dir, :source]
  defstruct [
    :name,
    :description,
    :location,
    :base_dir,
    :source,
    disable_model_invocation: false,
    metadata: %{}
  ]

  @type source :: :user | :project | :explicit

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          location: String.t(),
          base_dir: String.t(),
          source: source(),
          disable_model_invocation: boolean(),
          metadata: %{String.t() => term()}
        }

  @max_name_length 64
  @max_description_length 1024

  @doc """
  Build a Skill struct from parsed frontmatter and file info.

  Returns `{:ok, skill, diagnostics}` or `{:error, diagnostics}`
  if description is missing (skill not loaded).
  """
  @spec build(
          frontmatter :: map(),
          location :: String.t(),
          parent_dir_name :: String.t(),
          source :: source()
        ) :: {:ok, t(), [map()]} | {:error, [map()]}
  def build(frontmatter, location, parent_dir_name, source) do
    diagnostics = []

    name = Map.get(frontmatter, "name") || parent_dir_name
    {name, diagnostics} = validate_name(name, parent_dir_name, location, diagnostics)

    description = Map.get(frontmatter, "description", "")

    {description_ok, diagnostics} =
      validate_description(description, location, diagnostics)

    if not description_ok do
      {:error, diagnostics}
    else
      disable_invoke =
        Map.get(frontmatter, "disable-model-invocation", false) == true

      known_keys = ["name", "description", "disable-model-invocation"]
      metadata = Map.drop(frontmatter, known_keys)

      skill = %__MODULE__{
        name: name,
        description: description,
        location: location,
        base_dir: Path.dirname(location),
        source: source,
        disable_model_invocation: disable_invoke,
        metadata: metadata
      }

      {:ok, skill, diagnostics}
    end
  end

  defp validate_name(name, parent_dir_name, file_path, diagnostics) do
    d = diagnostics

    d =
      if name != parent_dir_name do
        [
          %{
            type: :warning,
            message: "name \"#{name}\" does not match parent directory \"#{parent_dir_name}\"",
            path: file_path
          }
          | d
        ]
      else
        d
      end

    d =
      if String.length(name) > @max_name_length do
        [
          %{
            type: :warning,
            message: "name exceeds #{@max_name_length} characters (#{String.length(name)})",
            path: file_path
          }
          | d
        ]
      else
        d
      end

    d =
      if not Regex.match?(~r/^[a-z0-9-]+$/, name) do
        [
          %{
            type: :warning,
            message:
              "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)",
            path: file_path
          }
          | d
        ]
      else
        d
      end

    d =
      if String.starts_with?(name, "-") or String.ends_with?(name, "-") do
        [
          %{
            type: :warning,
            message: "name must not start or end with a hyphen",
            path: file_path
          }
          | d
        ]
      else
        d
      end

    d =
      if String.contains?(name, "--") do
        [
          %{
            type: :warning,
            message: "name must not contain consecutive hyphens",
            path: file_path
          }
          | d
        ]
      else
        d
      end

    {name, d}
  end

  defp validate_description(desc, file_path, diagnostics) do
    trimmed = String.trim(desc)

    if trimmed == "" do
      d =
        [
          %{
            type: :error,
            message: "description is required",
            path: file_path
          }
          | diagnostics
        ]

      {false, d}
    else
      d =
        if String.length(desc) > @max_description_length do
          [
            %{
              type: :warning,
              message:
                "description exceeds #{@max_description_length} characters (#{String.length(desc)})",
              path: file_path
            }
            | diagnostics
          ]
        else
          diagnostics
        end

      {true, d}
    end
  end
end
