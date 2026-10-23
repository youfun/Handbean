defmodule Handbean.Extension.Loader do
  @moduledoc """
  Discovers extension manifests from the filesystem.

  Does NOT execute extension code. Only parses extension.json/manifest.json files.

  Discovery locations:
  - user: ~/.handbean/extensions
  - project: {workspace}/.handbean/extensions
  - explicit: single directory, single manifest, or parent directory

  Priority: project overrides user for duplicate names.
  """

  alias Handbean.Extension.Manifest
  alias Handbean.Extension.Diagnostic

  defmodule Result do
    @moduledoc false
    defstruct extensions: [], scoped_extensions: [], diagnostics: []

    @type t :: %__MODULE__{
            extensions: [Handbean.Extension.t()],
            diagnostics: [Diagnostic.t()]
          }
  end

  @doc """
  Loads extensions from project workspace.

  Scans `{workspace}/.handbean/extensions/` for extension directories
  containing `extension.json` or `manifest.json`.
  """
  @spec from_project(String.t()) :: Result.t()
  def from_project(workspace) do
    dir = Path.join(workspace, ".handbean/extensions")

    if File.dir?(dir) do
      result = load_from_dir(dir, :project)
      {:ok, canonical} = Handbean.Security.PathValidator.canonicalize(workspace)
      %{result | extensions: Enum.map(result.extensions, &%{&1 | scope: {:project, canonical}})}
    else
      %Result{}
    end
  end

  @doc """
  Loads extensions from user home.

  Scans `{home}/.handbean/extensions/` for extension directories.
  """
  @spec from_user(String.t()) :: Result.t()
  def from_user(home) do
    dir = Path.join(home, ".handbean/extensions")

    if File.dir?(dir) do
      result = load_from_dir(dir, :user)
      %{result | extensions: Enum.map(result.extensions, &%{&1 | scope: :user})}
    else
      %Result{}
    end
  end

  @doc """
  Loads extensions from an explicit path.

  The path can be:
  - a single extension directory (containing extension.json)
  - a parent directory containing multiple extension directories
  """
  @spec from_explicit(String.t()) :: Result.t()
  def from_explicit(path) do
    cond do
      not File.exists?(path) ->
        %Result{
          diagnostics: [
            %Diagnostic{
              type: :validation_error,
              message: "extension path does not exist: #{path}"
            }
          ]
        }

      extension_dir?(path) ->
        load_single_extension(path, :explicit)

      File.dir?(path) ->
        load_from_dir(path, :explicit)

      true ->
        %Result{
          diagnostics: [
            %Diagnostic{
              type: :validation_error,
              message: "not a valid extension path: #{path}"
            }
          ]
        }
    end
  end

  @doc """
  Combined load: project extensions + user extensions.

  Project extensions take priority over user extensions for duplicate names.
  """
  @spec load(keyword()) :: Result.t()
  def load(opts \\ []) do
    project = Keyword.get(opts, :project)
    user_home = Keyword.get(opts, :user_home)

    user_result = if user_home, do: from_user(user_home), else: %Result{}
    proj_result = if project, do: from_project(project), else: %Result{}
    merge_results(user_result, proj_result)
  end

  # ── Private helpers ──

  defp load_from_dir(dir, source) do
    dir
    |> discover_extension_dirs()
    |> Enum.reduce(%Result{}, fn ext_dir, acc ->
      result = load_single_extension(ext_dir, source)

      # Merge: first wins (keeping existing), add collision diagnostic for later
      # Use prepend+reverse instead of ++ for O(n) instead of O(n²)
      merged_extensions =
        result.extensions
        |> Enum.reduce(acc.extensions, fn ext, exts ->
          case Enum.find(exts, fn e -> e.name == ext.name end) do
            nil -> [ext | exts]
            _existing -> exts
          end
        end)
        |> Enum.reverse()

      new_diagnostics =
        if length(merged_extensions) < length(acc.extensions) + length(result.extensions) do
          collision_names =
            result.extensions
            |> Enum.filter(fn ext ->
              Enum.any?(acc.extensions, fn e -> e.name == ext.name end)
            end)
            |> Enum.map(& &1.name)

          Enum.map(collision_names, fn name -> collision_diagnostic(name, source) end)
        else
          []
        end

      %{
        acc
        | extensions: merged_extensions,
          diagnostics: acc.diagnostics ++ result.diagnostics ++ new_diagnostics
      }
    end)
  end

  defp load_single_extension(dir, source) do
    manifest_path = find_manifest(dir)

    case manifest_path do
      nil ->
        %Result{
          diagnostics: [
            %Diagnostic{
              type: :validation_error,
              message: "no extension.json or manifest.json found in #{dir}"
            }
          ]
        }

      path ->
        load_manifest_file(path, dir, source)
    end
  end

  # 1 MiB
  @max_manifest_size 1_048_576
  @max_discovery_depth 4

  # ── Public API ──

  defp load_manifest_file(path, dir, _source) do
    case check_manifest_size(path) do
      :ok ->
        case File.read(path) do
          {:ok, content} ->
            case Manifest.from_json(content) do
              {:ok, manifest} ->
                with {:ok, canonical_root} <- Handbean.Security.PathValidator.canonicalize(dir),
                     {:ok, ext} <- Handbean.Extension.new(manifest, canonical_root) do
                  %Result{extensions: [ext]}
                else
                  {:error, %Diagnostic{} = diagnostic} ->
                    %Result{diagnostics: [diagnostic]}

                  {:error, _reason} ->
                    %Result{
                      diagnostics: [
                        %Diagnostic{
                          type: :validation_error,
                          message: "Cannot resolve extension root"
                        }
                      ]
                    }
                end

              {:error, diagnostic} ->
                %Result{diagnostics: [diagnostic]}
            end

          {:error, reason} ->
            %Result{
              diagnostics: [
                %Diagnostic{
                  type: :parse_error,
                  message: "failed to read #{path}: #{reason}"
                }
              ]
            }
        end

      {:error, reason} ->
        %Result{
          diagnostics: [
            %Diagnostic{
              type: :validation_error,
              message: "manifest file #{path} is too large (#{reason}): skipping"
            }
          ]
        }
    end
  end

  defp check_manifest_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_manifest_size ->
        :ok

      {:ok, %{size: size}} ->
        {:error, "#{size} bytes (max #{@max_manifest_size})"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discover_extension_dirs(parent_dir) do
    case File.ls(parent_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          not String.starts_with?(name, ".") and name != "node_modules"
        end)
        |> Enum.map(&Path.join(parent_dir, &1))
        |> Enum.filter(&safe_dir?/1)
        |> Enum.flat_map(fn dir ->
          if extension_dir?(dir) do
            [dir | discover_subdirs(dir, 1)]
          else
            discover_subdirs(dir, 1)
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp discover_subdirs(_dir, depth) when depth >= @max_discovery_depth, do: []

  defp discover_subdirs(dir, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          not String.starts_with?(name, ".") and name != "node_modules"
        end)
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&safe_dir?/1)
        |> Enum.flat_map(fn subdir ->
          if extension_dir?(subdir) do
            [subdir | discover_subdirs(subdir, depth + 1)]
          else
            discover_subdirs(subdir, depth + 1)
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Skip symlinks to prevent symlink-based directory traversal and cycles.
  # File.dir?/1 follows symlinks; File.lstat gives us the real type.
  defp safe_dir?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> File.dir?(path)
      {:ok, _} -> false
      {:error, _} -> false
    end
  end

  defp extension_dir?(dir) do
    File.dir?(dir) and find_manifest(dir) != nil
  end

  defp find_manifest(dir) do
    ext_json = Path.join(dir, "extension.json")
    manifest_json = Path.join(dir, "manifest.json")

    cond do
      File.exists?(ext_json) -> ext_json
      File.exists?(manifest_json) -> manifest_json
      true -> nil
    end
  end

  defp merge_results(user, project) do
    # Project extensions override user extensions with same name
    project_names = Enum.map(project.extensions, & &1.name) |> MapSet.new()

    user_exts =
      Enum.reject(user.extensions, fn ext -> MapSet.member?(project_names, ext.name) end)

    %Result{
      extensions: user_exts ++ project.extensions,
      scoped_extensions: user.extensions ++ project.extensions,
      diagnostics: user.diagnostics ++ project.diagnostics
    }
  end

  defp collision_diagnostic(name, source) do
    %Diagnostic{
      type: :collision,
      message: "extension name collision: #{name} already loaded (from #{source})",
      details: %{name: name, source: source}
    }
  end
end
