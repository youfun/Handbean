defmodule Handbean.Agent.ContextLoader do
  @moduledoc """
  Discovers, loads, truncates, and injects AGENTS.md context files
  into the agent's system prompt.

  ## Discovery

  Walks from `cwd` upward through parent directories collecting every
  `AGENTS.md` file, and also reads `AGENTS.md` in each immediate child of the
  workspace root. The walk stops at the workspace root when one is given,
  otherwise at the filesystem root. A `mix.exs` file is not a boundary.
  Paths are sorted by depth ascending — shallowest (lowest priority) first,
  deepest (highest priority) last.

  ## Loading

  Each file is read and annotated with its source path. Unreadable or
  missing files are skipped with a `Logger.warning/1` — the agent
  session never fails because of a bad AGENTS.md.

  ## Truncation

  Two hard limits protect the context window:

    - **Per-file**: 2 000 characters (default)
    - **Total**: 8 000 characters (default)

  When a limit is hit a `[TRUNCATED: ...]` marker is inserted. Files
  are never summarised or rewritten — truncated content is unambiguous.

  ## Injection

  The merged context is injected as a standalone `## Project Instructions
  (AGENTS.md)` section near the top of the system prompt. When the
  context is empty or nil the prompt is returned unchanged.
  """

  require Logger

  @max_per_file 2000
  @max_total 8000
  @skipped_children ~w(node_modules _build deps .git priv .gradle .elixir_ls)

  @doc """
  Discover AGENTS.md files walking upward from `cwd`.

  Pass `workspace:` to stop at that directory and include `AGENTS.md` files
  in its immediate children. Deeper files and files outside the workspace are
  not project instructions. Without it, the walk stops at the filesystem root.
  It does not stop at `mix.exs`.

  Returns absolute paths sorted by directory depth (shallowest first).

  ## Examples

      iex> paths = ContextLoader.discover()
      iex> is_list(paths)
      true
  """
  @spec discover(String.t(), keyword()) :: [String.t()]
  def discover(cwd \\ File.cwd!(), opts \\ []) do
    workspace = Keyword.get(opts, :workspace)

    cwd
    |> walk_up(workspace)
    |> Kernel.++(child_agents(workspace))
    |> Enum.filter(&File.exists?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&{depth(&1), &1})
  end

  @doc """
  Load and merge discovered AGENTS.md files.

  Each file is annotated with its source path. Files that cannot be
  read (missing, permission denied) are skipped with a warning log.

  Returns `{:ok, merged_content}`. Never returns an error tuple —
  even when every file fails the result is `{:ok, ""}`.
  """
  @spec load([String.t()]) :: {:ok, String.t()}
  def load(paths) do
    sections =
      paths
      |> Enum.map(&load_one/1)
      |> Enum.reject(&is_nil/1)

    {:ok, Enum.join(sections)}
  end

  @doc """
  Truncate merged context to per-file and total character limits.

  Returns `{truncated_content, truncated?}`.

  ## Options

    - `:max_per_file` — chars per file section (default: 2 000)
    - `:max_total` — total chars across all sections (default: 8 000)
  """
  @spec truncate(String.t(), keyword()) :: {String.t(), boolean()}
  def truncate(content, opts \\ []) do
    max_per_file = Keyword.get(opts, :max_per_file, @max_per_file)
    max_total = Keyword.get(opts, :max_total, @max_total)

    {sections, per_file_truncated?} = truncate_per_file(content, max_per_file)

    if per_file_truncated? do
      {truncate_total(sections, max_total, true), true}
    else
      {truncate_total(sections, max_total, false), false}
    end
  end

  @doc """
  Inject AGENTS.md context into a system prompt.

  When `context` is empty or nil the prompt is returned unchanged.

  ## Examples

      iex> ContextLoader.inject("Be helpful.", "# rule")
      ...> |> String.contains?("## Project Instructions (AGENTS.md)")
      true
  """
  @spec inject(String.t(), String.t() | nil) :: String.t()
  def inject(system_prompt, context) when is_binary(context) and context != "" do
    section = """

    ## Project Instructions (AGENTS.md)

    #{String.trim_trailing(context)}
    """

    system_prompt <> section
  end

  def inject(system_prompt, _context), do: system_prompt

  # ── Private: discovery ──

  defp walk_up(dir, workspace) do
    stop = workspace && Path.expand(workspace)

    Stream.unfold(dir, fn
      nil ->
        nil

      d ->
        expanded = Path.expand(d)
        {Path.join(expanded, "AGENTS.md"), if(expanded == stop, do: nil, else: parent(expanded))}
    end)
    |> Enum.to_list()
  end

  defp child_agents(nil), do: []

  defp child_agents(workspace) do
    root = Path.expand(workspace)

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(&child_agent(root, &1))

      _ ->
        []
    end
  end

  defp child_agent(root, name) do
    dir = Path.join(root, name)
    path = Path.join(dir, "AGENTS.md")

    if child_dir?(name, dir) and regular_file?(path), do: [path], else: []
  end

  defp child_dir?(name, dir) do
    not String.starts_with?(name, ".") and name not in @skipped_children and
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir))
  end

  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp parent(dir) do
    parent = Path.dirname(dir)

    if parent == dir do
      nil
    else
      parent
    end
  end

  defp depth(path) do
    path
    |> Path.dirname()
    |> Path.split()
    |> length()
  end

  # ── Private: loading ──

  defp load_one(path) do
    case File.read(path) do
      {:ok, content} ->
        "\n### From: #{path}\n#{String.trim_trailing(content)}\n"

      {:error, reason} ->
        Logger.warning("[ContextLoader] Skipping #{path}: #{:file.format_error(reason)}")

        nil
    end
  end

  # ── Private: per-file truncation ──

  @section_separator "\n### From:"

  defp truncate_per_file("", _max_per_file), do: {[], false}

  defp truncate_per_file(content, max_per_file) do
    sections = split_sections(content)

    Enum.map_reduce(sections, false, fn section, acc ->
      if String.length(section) <= max_per_file do
        {section, acc}
      else
        truncated = String.slice(section, 0, max_per_file)

        marker =
          "\n[TRUNCATED: exceeds #{max_per_file} chars per file]"

        {truncated <> marker, true}
      end
    end)
  end

  defp split_sections(content) do
    content
    |> String.split(@section_separator)
    |> Enum.with_index()
    |> Enum.map(fn
      {section, 0} -> section
      {section, _} -> @section_separator <> section
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # ── Private: total truncation ──

  defp truncate_total(sections, max_total, already_truncated?) do
    result = do_truncate_total(sections, max_total)

    if result == sections and not already_truncated? do
      # Nothing was truncated — return the joined content
      Enum.join(sections)
    else
      truncated? = result != sections or already_truncated?

      if truncated? do
        joined = Enum.join(result)
        marker = "[TRUNCATED: total exceeds #{max_total} chars]"

        if byte_size(joined) == 0 and sections != [] do
          # All files were dropped — just return the marker
          marker
        else
          joined <> "\n" <> marker
        end
      else
        Enum.join(result)
      end
    end
  end

  defp do_truncate_total(sections, max_total) do
    # Keep highest-priority files (from the end), drop lower-priority ones
    # until total byte_size fits within max_total.
    # Reserve some space for the truncation marker.
    reserved = byte_size("[TRUNCATED: total exceeds 99999 chars]")

    Enum.reduce(Enum.reverse(sections), {[], 0}, fn section, {acc, total} ->
      section_bytes = byte_size(section)

      if total + section_bytes <= max_total - reserved do
        {[section | acc], total + section_bytes}
      else
        {acc, total}
      end
    end)
    |> elem(0)
  end
end
