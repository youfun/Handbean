defmodule Handbean.Search.ExFffBackend do
  @moduledoc false

  @behaviour Handbean.Search.Backend

  @impl true
  def ensure_started(workspace) do
    with {:ok, index} <-
           ExFff.Index.ensure_started(workspace, path_filter: &lexically_allowed?/1) do
      Handbean.Search.Watcher.watch(workspace, index)
      {:ok, index}
    end
  end

  @impl true
  def await(index, timeout), do: ExFff.Index.await_index(index, timeout)

  @impl true
  def search(index, query, opts), do: ExFff.Index.search(index, query, opts)

  @impl true
  def files(index, opts), do: ExFff.Index.files(index, opts)

  @impl true
  def touch(index, path), do: ExFff.Index.touch(index, path)

  @impl true
  def update_paths(index, paths), do: ExFff.Index.update_paths(index, paths)

  @impl true
  def set_git_status(index, entries), do: ExFff.Index.set_git_status(index, entries)

  @impl true
  def ignored_path?(workspace, path) do
    config = ExFff.Config.new(root_path: workspace, path_filter: &lexically_allowed?/1)
    ExFff.Scanner.ignored_path?(workspace, path, config)
  end

  @impl true
  def refresh(index), do: ExFff.Index.refresh(index)

  defp lexically_allowed?(path) do
    Handbean.Security.PathValidator.reject_sensitive(path) == :ok
  end
end
