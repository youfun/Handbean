defmodule Handbean.Skills.Loader do
  @moduledoc """
  Skill Loader — discovers and loads skills from filesystem locations.

  Discovery rules:
  1. If a directory contains SKILL.md, it is a skill root — stop recursion.
  2. Supports recursive discovery of SKILL.md in subdirectories.
  3. Skips hidden directories, node_modules, unreadable files and symlinks.
  4. .gitignore / .ignore / .fdignore support is P1 — not yet implemented.

  Skill files are limited to 64 KiB of UTF-8 text. Configured roots may not
  redirect through symlinks outside their trusted workspace/home anchor.
  The release also loads bundled skills from this application's `priv/skills`
  (OTP app `:handbean`). That directory is part of the installed BEAM release,
  not a workspace or home path. Project, user, and explicit skills win on name
  collision. Mix may copy or link the whole `priv` directory into `_build`;
  that install-path link is resolved to a canonical priv anchor. The `skills`
  directory under that anchor, and every path in the skill tree, must not be
  a symlink.
  Symlinks within a skill tree are conservatively unsupported, including
  links whose targets are inside the tree. This is not an OS filesystem sandbox.
  Validation and file opening are separate operations, not an atomic guarantee
  against a hostile local process concurrently replacing filesystem entries.
  """

  alias Handbean.Security.PathValidator
  alias Handbean.Skills.Skill

  @max_file_bytes 65_536

  defmodule LoadResult do
    @moduledoc false
    defstruct skills: [], diagnostics: []
  end

  @type load_result :: %LoadResult{
          skills: [Skill.t()],
          diagnostics: [map()]
        }

  @doc """
  Load skills from configured workspace and user locations.

  Project skill directories are loaded before user-level directories so a project
  skill wins when it has the same name as a global skill.
  Trusted `:skill_paths` are loaded after those defaults, only within the
  workspace or the allowed global skill roots. Arbitrary host paths are not
  skill sources. Bundled `priv/skills` are loaded last so any of the above
  override a shipped skill of the same name.
  """
  @spec load(keyword()) :: load_result()
  def load(opts \\ []) do
    Enum.reduce(skill_dirs(opts), %LoadResult{}, fn {dir, source}, acc ->
      sub = load_from_dir(dir, source)
      merge_result(acc, sub)
    end)
  end

  @doc """
  Load current content by discovered name for model invocation.

  Rechecks both the file boundary and current frontmatter at invocation time.
  User `/skill:` expansion remains independent of model-invocation permission.

  ## Examples

      iex> Handbean.Skills.Loader.load_named("../secret", workspace: "/tmp")
      {:error, "Invalid skill name"}
  """
  def load_named(name, opts \\ []) do
    with :ok <- validate_name(name) do
      result = load(opts)

      case Enum.find(result.skills, &(&1.name == name)) do
        nil ->
          {:error, "Unknown or unavailable skill (missing, unreadable, unsafe or oversized)"}

        skill ->
          with {:ok, current, _diagnostics, content} <-
                 load_skill_file(skill.location, skill.source),
               :ok <- validate_invocation(current, name) do
            {:ok, current, content}
          else
            {:error, reason} when is_binary(reason) -> {:error, reason}
            {:error, _diagnostics} -> {:error, "Skill is no longer readable or safe"}
          end
      end
    end
  end

  @doc "Load skills from a single directory."
  @spec load_from_dir(String.t(), Skill.source()) :: load_result()
  def load_from_dir(dir, source) do
    do_load_from_dir(Path.expand(dir), source)
  end

  # ── Internal ──

  defp skill_dirs(opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    anchors = [
      {workspace, :project},
      {Keyword.get(opts, :user_home, Handbean.Home.path()), :user}
    ]

    dirs =
      Enum.flat_map(anchors, fn {anchor, source} ->
        case PathValidator.canonicalize(anchor) do
          {:ok, resolved} ->
            [
              {Path.join(resolved, ".handbean/skills"), source},
              {Path.join(resolved, ".agents/skills"), source}
            ]

          {:error, _} ->
            []
        end
      end)

    user_roots = for {dir, :user} <- dirs, validate_unlinked(dir) == :ok, do: dir
    allowed_roots = [workspace | user_roots]

    explicit_dirs =
      for path <- List.wrap(Keyword.get(opts, :skill_paths, [])),
          is_binary(path),
          expanded = Path.expand(path, workspace),
          Enum.any?(
            allowed_roots,
            &(PathValidator.validate_within_workspace(expanded, &1) == :ok)
          ),
          do: {expanded, :explicit}

    dirs ++ explicit_dirs ++ bundled_dirs()
  end

  defp bundled_dirs do
    bundled_dirs_from_priv(Application.app_dir(:handbean, "priv"))
  end

  @doc false
  def bundled_dirs_from_priv(priv) when is_binary(priv) do
    with {:ok, priv_anchor} <- PathValidator.canonicalize(priv),
         {:ok, %{type: :directory}} <- File.lstat(priv_anchor),
         skills = Path.join(priv_anchor, "skills"),
         :ok <- validate_unlinked(skills),
         {:ok, %{type: :directory}} <- File.lstat(skills) do
      [{skills, :bundled}]
    else
      _ -> []
    end
  end

  defp validate_name(name) when is_binary(name) do
    if byte_size(name) in 1..256 and String.valid?(name) and
         not String.contains?(name, ["/", "\\", "\0"]) and name not in [".", ".."] do
      :ok
    else
      {:error, "Invalid skill name"}
    end
  end

  defp validate_name(_), do: {:error, "Invalid skill name"}

  defp validate_invocation(%Skill{name: name, disable_model_invocation: false}, name),
    do: :ok

  defp validate_invocation(%Skill{disable_model_invocation: true}, _),
    do:
      {:error,
       "Skill disables model invocation; only an explicit user /skill: command may load it"}

  defp validate_invocation(_, _), do: {:error, "Skill name changed; discover skills again"}

  defp do_load_from_dir(dir, source) do
    with :ok <- validate_unlinked(dir),
         {:ok, %{type: :directory}} <- File.lstat(dir),
         {:ok, entries} <- File.ls(dir) do
      if "SKILL.md" in entries do
        full_path = Path.join(dir, "SKILL.md")

        case load_skill_file(full_path, source) do
          {:ok, skill, diagnostics, _content} ->
            %LoadResult{skills: [skill], diagnostics: diagnostics}

          {:error, diagnostics} ->
            %LoadResult{diagnostics: diagnostics}
        end
      else
        Enum.reduce(Enum.sort(entries), %LoadResult{}, fn entry, acc ->
          next = Path.join(dir, entry)

          if String.starts_with?(entry, ".") || entry == "node_modules" do
            acc
          else
            sub = do_load_from_dir(next, source)
            merge_result(acc, sub)
          end
        end)
      end
    else
      _ -> %LoadResult{}
    end
  end

  defp load_skill_file(file_path, source) do
    case read_content(file_path) do
      {:error, reason} ->
        {:error,
         [
           %{
             type: :error,
             message: "failed to read skill file: #{inspect(reason)}",
             path: file_path
           }
         ]}

      {:ok, content} ->
        {frontmatter, _} = parse_frontmatter(content)
        parent_dir_name = file_path |> Path.dirname() |> Path.basename()

        if is_binary(Map.get(frontmatter, "name", parent_dir_name)) and
             is_binary(Map.get(frontmatter, "description", "")) do
          case Skill.build(frontmatter, file_path, parent_dir_name, source) do
            {:ok, skill, diagnostics} -> {:ok, skill, diagnostics, content}
            {:error, diagnostics} -> {:error, diagnostics}
          end
        else
          {:error,
           [%{type: :error, message: "name and description must be strings", path: file_path}]}
        end
    end
  end

  defp validate_unlinked(path) do
    case PathValidator.canonicalize(path) do
      {:ok, ^path} -> :ok
      _ -> {:error, :symlink_not_allowed}
    end
  end

  defp read_content(path) do
    with :ok <- validate_unlinked(path),
         {:ok, %{type: :regular, size: size, access: access, mode: mode}} <- File.lstat(path),
         true <- size <= @max_file_bytes,
         true <- access in [:read, :read_write] and Bitwise.band(mode, 0o444) != 0,
         {:ok, result} <- File.open(path, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
      validate_content(result)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unreadable_or_oversized}
    end
  end

  defp validate_content(content) when is_binary(content) do
    if byte_size(content) <= @max_file_bytes and String.valid?(content) and
         not String.contains?(content, "\0") do
      {:ok, content}
    else
      {:error, :oversized_or_invalid_text}
    end
  end

  defp validate_content(:eof), do: {:ok, ""}
  defp validate_content({:error, reason}), do: {:error, reason}

  @doc false
  def parse_frontmatter(content) do
    case String.split(content, "\n---\n", parts: 2) do
      [maybe_front, _body] ->
        front_str =
          maybe_front
          |> String.trim_leading("---\n")
          |> String.trim_leading("---")

        parsed = parse_yaml_like(front_str)
        {parsed, []}

      _ ->
        {%{}, []}
    end
  end

  defp parse_yaml_like(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          trimmed_key = String.trim(key)
          trimmed_val = String.trim(value)

          trimmed_val =
            if (String.starts_with?(trimmed_val, "\"") and String.ends_with?(trimmed_val, "\"")) or
                 (String.starts_with?(trimmed_val, "'") and String.ends_with?(trimmed_val, "'")) do
              String.slice(trimmed_val, 1..-2//1)
            else
              trimmed_val
            end

          cond do
            trimmed_val == "true" -> Map.put(acc, trimmed_key, true)
            trimmed_val == "false" -> Map.put(acc, trimmed_key, false)
            true -> Map.put(acc, trimmed_key, trimmed_val)
          end

        _ ->
          acc
      end
    end)
  end

  @doc false
  def merge_result(%LoadResult{} = acc, %LoadResult{} = sub) do
    existing_names = MapSet.new(acc.skills, & &1.name)

    {new_skills, collision_diags} =
      Enum.reduce(sub.skills, {acc.skills, []}, fn skill, {skills, diags} ->
        if MapSet.member?(existing_names, skill.name) do
          existing = Enum.find(acc.skills, &(&1.name == skill.name))

          collision_diag = %{
            type: :collision,
            message: ~s(name "#{skill.name}" collision),
            path: skill.location,
            winner_path: existing.location
          }

          {skills, [collision_diag | diags]}
        else
          {[skill | skills], diags}
        end
      end)

    new_skills = Enum.reverse(new_skills)

    %LoadResult{
      skills: new_skills,
      diagnostics: acc.diagnostics ++ sub.diagnostics ++ collision_diags
    }
  end
end
