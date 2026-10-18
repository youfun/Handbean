defmodule ExFff.Scanner do
  @moduledoc """
  Filesystem directory scanner with pre-traversal directory pruning.

  Avoids descending into known build artifact directories, dependency folders,
  and user-configured ignore patterns before reading their contents.
  """

  require Logger

  @doc """
  Returns true if the directory name or relative directory path should be pruned
  immediately without recursing.
  """
  @spec prune_dir?(String.t(), String.t(), ExFff.Config.t()) :: boolean()
  def prune_dir?(dir_name, rel_path, config) do
    ExFff.Config.default_ignored_dir?(dir_name) or
      ExFff.Config.ignored?(config, rel_path <> "/")
  end

  @doc """
  Walks the filesystem starting at `root_path` and returns a list of relative file paths.
  Respects `config.max_files` and `config.ignore_patterns`.
  """
  @spec scan(String.t(), ExFff.Config.t()) :: [String.t()]
  def scan(root_path, config) do
    scan(root_path, config, fn _paths -> :ok end)
  end

  @doc """
  Walks the filesystem and reports each discovered directory's file batch while
  retaining the same return value as `scan/2`.

  The callback runs in the scanner process. Consumers should keep it cheap.
  """
  @spec scan(String.t(), ExFff.Config.t(), ([String.t()] -> any())) :: [String.t()]
  def scan(root_path, config, on_batch) when is_function(on_batch, 1) do
    ignore = ExFff.Ignore.root(root_path)
    walk([{"", root_path, ignore}], root_path, config, 0, [], on_batch)
  end

  @doc """
  Scans files and computes trigrams and file metadata in one pass.
  Suitable for running inside a background Task.
  """
  @spec scan_and_prepare(String.t(), ExFff.Config.t()) ::
          {:ok, non_neg_integer(), list(), list()}
  def scan_and_prepare(root_path, config) do
    paths = scan(root_path, config)

    {files_entries, trigram_entries} = prepare(paths, root_path)
    {:ok, length(files_entries), files_entries, trigram_entries}
  end

  @doc """
  Scans and prepares entries in batches so an index can expose partial results
  before the complete workspace walk finishes.
  """
  @spec scan_and_prepare(String.t(), ExFff.Config.t(), (list(), list() -> any())) ::
          {:ok, non_neg_integer()}
  def scan_and_prepare(root_path, config, on_batch) when is_function(on_batch, 2) do
    paths =
      scan(root_path, config, fn paths ->
        {files_entries, trigram_entries} = prepare(paths, root_path)

        if files_entries != [] do
          on_batch.(files_entries, trigram_entries)
        end
      end)

    {:ok, length(paths)}
  end

  @doc false
  @spec prepare_path(String.t(), String.t(), ExFff.Config.t()) ::
          {:ok, {String.t(), map()}, [{String.t(), String.t()}]} | :ignore
  def prepare_path(root_path, rel_path, config) do
    full_path = Path.join(root_path, rel_path)
    ignore = ExFff.Ignore.for_path(root_path, rel_path)

    with true <- valid_file?(rel_path, config, ignore),
         {:ok, %{type: :regular} = stat} <- File.lstat(full_path) do
      file_entry = {rel_path, %{mtime: stat.mtime, size: stat.size}}

      trigram_entries =
        rel_path
        |> String.downcase()
        |> ExFff.Matcher.tokenize()
        |> Enum.map(&{&1, rel_path})

      {:ok, file_entry, trigram_entries}
    else
      _ -> :ignore
    end
  end

  defp prepare(paths, root_path) do
    Enum.reduce(paths, {[], []}, fn rel_path, {f_acc, t_acc} ->
      case prepare_scanned_path(root_path, rel_path) do
        {:ok, file_entry, trig_entries} ->
          {[file_entry | f_acc], trig_entries ++ t_acc}

        :ignore ->
          {f_acc, t_acc}
      end
    end)
  end

  defp prepare_scanned_path(root_path, rel_path) do
    full_path = Path.join(root_path, rel_path)

    case File.lstat(full_path) do
      {:ok, %{type: :regular} = stat} ->
        file_entry = {rel_path, %{mtime: stat.mtime, size: stat.size}}

        trigrams =
          rel_path
          |> String.downcase()
          |> ExFff.Matcher.tokenize()
          |> Enum.map(&{&1, rel_path})

        {:ok, file_entry, trigrams}

      _ ->
        :ignore
    end
  end

  # ── Helpers ──

  defp walk([], _root, _config, _count, acc, _on_batch), do: Enum.reverse(acc)

  defp walk(_dirs, _root, config, count, acc, _on_batch) when count >= config.max_files,
    do: Enum.reverse(acc)

  defp walk([{rel, full_dir, inherited_ignore} | rest_dirs], root, config, count, acc, on_batch) do
    ignore =
      if rel == "" do
        inherited_ignore
      else
        ExFff.Ignore.extend(inherited_ignore, full_dir, rel)
      end

    case File.ls(full_dir) do
      {:ok, entries} ->
        {next_dirs, next_files, new_count} =
          process_entries(Enum.sort(entries), rel, full_dir, config, ignore, count)

        if next_files != [], do: on_batch.(Enum.reverse(next_files))

        walk(
          next_dirs ++ rest_dirs,
          root,
          config,
          new_count,
          next_files ++ acc,
          on_batch
        )

      {:error, reason} ->
        Logger.warning("[ExFff.Scanner] Skipping #{full_dir}: #{inspect(reason)}")
        walk(rest_dirs, root, config, count, acc, on_batch)
    end
  end

  defp process_entries(entries, rel, full_dir, config, ignore, count) do
    max_files = config.max_files

    Enum.reduce_while(entries, {[], [], count}, fn entry, {dirs_acc, files_acc, cur_count} ->
      child_rel = if rel == "", do: entry, else: Path.join(rel, entry)
      child_full = Path.join(full_dir, entry)

      cond do
        prune_dir?(entry, child_rel, config, ignore) and directory?(child_full) ->
          {:cont, {dirs_acc, files_acc, cur_count}}

        cur_count >= max_files ->
          {:halt, {dirs_acc, files_acc, cur_count}}

        true ->
          next =
            case File.lstat(child_full) do
              {:ok, %{type: :directory}} ->
                {[{child_rel, child_full, ignore} | dirs_acc], files_acc, cur_count}

              {:ok, %{type: :regular}} ->
                if valid_file?(child_rel, config, ignore) do
                  {dirs_acc, [child_rel | files_acc], cur_count + 1}
                else
                  {dirs_acc, files_acc, cur_count}
                end

              _ ->
                {dirs_acc, files_acc, cur_count}
            end

          {:cont, next}
      end
    end)
  end

  defp directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> true
      _ -> false
    end
  end

  @doc false
  def ignored_path?(root_path, path, config) do
    case relative_path(root_path, path) do
      nil -> true
      relative -> not valid_file?(relative, config, ExFff.Ignore.for_path(root_path, relative))
    end
  end

  defp prune_dir?(dir_name, rel_path, config, ignore) do
    prune_dir?(dir_name, rel_path, config) or ExFff.Ignore.prune?(ignore, rel_path)
  end

  defp valid_file?(rel_path, config, ignore) do
    try do
      String.valid?(rel_path) and
        not ExFff.Config.ignored?(config, rel_path) and
        not ExFff.Ignore.ignored?(ignore, rel_path) and
        ExFff.Config.allowed?(config, rel_path)
    rescue
      _ -> false
    end
  end

  defp relative_path(root_path, path) do
    root = Path.expand(root_path)

    expanded =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, root)

    if expanded != root and String.starts_with?(expanded, root <> "/") do
      Path.relative_to(expanded, root)
    end
  end
end
