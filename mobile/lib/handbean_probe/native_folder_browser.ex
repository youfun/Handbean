defmodule HandbeanProbe.NativeFolderBrowser do
  @moduledoc """
  In-app directory picker limited to app-readable roots.

  `start/2` with `lazy: true` (the screen path) returns a browser whose
  `entries` are still `loading?`; the owner lists the directory off-process
  with `list/2` and installs the result with `put_entries/3`. `start/1`
  without the option lists synchronously and is kept for callers that are
  not a screen process.
  """

  def start(root \\ default_root(), opts \\ []) do
    lazy? = Keyword.get(opts, :lazy, false)
    root = Path.expand(root || if(lazy?, do: Handbean.Host.data_dir(), else: default_root()))

    if lazy? do
      %{root: root, path: root, entries: [], lazy?: true, loading?: true}
    else
      %{root: root, path: root, entries: entries(root, root), lazy?: false, loading?: false}
    end
  end

  def action(:up, state) do
    parent = Path.dirname(state.path)

    if allowed?(parent, state.root) and parent != state.path do
      move(state, parent)
    else
      state
    end
  end

  def action(:select, state), do: {:select, state.path}

  def action({:enter, name}, state) do
    dest = Path.join(state.path, name)

    if allowed?(dest, state.root) and File.dir?(dest) do
      move(state, dest)
    else
      state
    end
  end

  def action(_, state), do: state

  defp move(%{lazy?: true} = state, dest), do: %{state | path: dest, entries: [], loading?: true}
  defp move(state, dest), do: %{state | path: dest, entries: entries(dest, state.root)}

  def loading?(state), do: Map.get(state, :loading?) == true

  @doc "List child directories of `path` under `root`. Runs off the screen process."
  def list(path, root) do
    if path == root, do: _ = File.mkdir_p(root)
    entries(path, root)
  end

  @doc "Install listed `entries` when the browser is still at `path`."
  def put_entries(%{path: path} = state, path, entries),
    do: %{state | entries: entries, loading?: false}

  def put_entries(state, _path, _entries), do: state

  @doc """
  True when `path` is `root` or a real (non-symlink) entry under `root`.

  Containment is component-wise via `Path.safe_relative_to/2`, so a sibling
  such as `/tmp/ws2` is never accepted for root `/tmp/ws`. The target itself is
  `File.lstat`-checked so a symlink pointing outside the root is rejected even
  though `File.dir?/1` would follow it.
  """
  def allowed?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)

    cond do
      path == root -> true
      not under_root?(path, root) -> false
      true -> not symlink?(path)
    end
  end

  defp under_root?(path, root) do
    rel = Path.relative_to(path, root, force: true)
    match?({:ok, _}, Path.safe_relative_to(rel, root))
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp entries(path, root) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          dest = Path.join(path, name)

          if name not in [".", ".."] and File.dir?(dest) and allowed?(dest, root) do
            [%{name: name, path: dest}]
          else
            []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp default_root do
    dir = Handbean.Host.data_dir()
    File.mkdir_p!(dir)
    dir
  end
end
