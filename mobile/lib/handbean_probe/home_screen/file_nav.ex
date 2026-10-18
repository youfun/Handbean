defmodule HandbeanProbe.HomeScreen.FileNav do
  @moduledoc """
  Workspace and file navigation: the workspace settings page (list, create,
  in-app folder browser, Android folder import), the workspace file tree,
  and the unified file open / viewer overlay.

  Directory listing for the folder browser runs under
  `HandbeanProbe.TaskSupervisor` and returns as
  `{:folder_listed, generation, {path, entries}}`; tree listing and file open
  already run off-screen inside `NativeWorkspaceTree` / `NativeWorkspaceOpen`.
  A workspace switch chosen here is applied by `HandbeanProbe.HomeScreen.Nav`.
  """

  import Mob.Socket, only: [assign: 3]

  alias HandbeanProbe.HomeScreen.{Async, Nav, Notice}

  alias HandbeanProbe.{
    NativeFolderBrowser,
    NativeWorkspaceOpen,
    NativeWorkspaces,
    NativeWorkspaceTree
  }

  # ── file open / viewer ──

  def handle({:tap, {:workspace_open, :view, spec}}, socket),
    do: NativeWorkspaceOpen.request(socket, spec)

  def handle({:workspace_open_ready, generation, result}, socket),
    do: NativeWorkspaceOpen.handle_ready(socket, generation, result)

  def handle({:tap, :close_file_viewer}, socket), do: NativeWorkspaceOpen.close(socket)

  def handle({:tap, :file_viewer_open_external}, socket),
    do: NativeWorkspaceOpen.system_open(socket)

  def handle({:tap, :file_viewer_share}, socket), do: NativeWorkspaceOpen.share(socket)

  # ── file tree ──

  def handle({:tap, {:file_tree, action}}, socket), do: NativeWorkspaceTree.handle(socket, action)

  def handle({:file_tree_listed, payload}, socket) when is_map(payload),
    do: NativeWorkspaceTree.handle_listed(socket, payload)

  # ── workspace settings page ──

  def handle({:change, :workspace_name, value}, socket),
    do: workspace_action(socket, {:change_name, value})

  def handle({:tap, :open_create}, socket), do: workspace_action(socket, :open_create)
  def handle({:tap, :create_workspace}, socket), do: workspace_action(socket, :create)
  def handle({:tap, :workspace_list}, socket), do: workspace_action(socket, :open_list)
  def handle({:tap, :open_browse}, socket), do: workspace_action(socket, :open_browse)
  def handle({:tap, {:browse, action}}, socket), do: workspace_action(socket, {:browse, action})
  def handle({:tap, :start_import}, socket), do: workspace_action(socket, :start_import)
  def handle({:tap, :cancel_import}, socket), do: workspace_action(socket, :cancel_import)
  def handle({:tap, {:toggle_path, id}}, socket), do: workspace_action(socket, {:toggle_path, id})

  def handle({:files, :cancelled}, socket) do
    if HandbeanProbe.NativePlatform.ios?() and
         HandbeanProbe.Platform.IOS.consume_files_event(:cancelled) == :handled do
      socket
    else
      workspace_action(socket, {:files, :cancelled})
    end
  end

  def handle({:files, :picked, items}, socket) do
    if HandbeanProbe.NativePlatform.ios?() and
         HandbeanProbe.Platform.IOS.consume_files_event({:picked, items}) == :handled do
      socket
    else
      workspace_action(socket, {:files, :picked, items})
    end
  end

  @doc """
  `Handbean.Host` directory picker (see `HandbeanProbe.DirectoryPicker`): open the
  workspace page on the in-app folder browser.
  """
  def handle({:directory_picker, _ctx}, socket) do
    socket
    |> assign(:page, :workspace)
    |> Notice.clear()
    |> workspace_action(:open_browse)
  end

  @doc "Latest `:folder_listed` reply; staleness is settled by `Requests.take/3`."
  def handle_folder_listed(socket, {path, entries}) do
    assign(
      socket,
      :workspaces,
      NativeWorkspaces.put_browser_entries(socket.assigns.workspaces, path, entries)
    )
  end

  defp workspace_action(socket, action) do
    case NativeWorkspaces.action(action, socket.assigns.workspaces, socket.assigns.workspace) do
      {:switch, workspace, conversation, workspaces} ->
        socket
        |> Nav.apply_workspace(workspace, conversation)
        |> assign(:workspaces, workspaces)

      workspaces ->
        socket
        |> assign(:workspaces, workspaces)
        |> Notice.put_error(workspaces.error)
        |> list_folder_if_loading()
    end
  end

  defp list_folder_if_loading(
         %{assigns: %{workspaces: %{mode: :browse, browser: browser}}} = socket
       )
       when is_map(browser) do
    if NativeFolderBrowser.loading?(browser) do
      %{path: path, root: root} = browser
      Async.run(socket, :folder_listed, fn -> {path, NativeFolderBrowser.list(path, root)} end)
    else
      socket
    end
  end

  defp list_folder_if_loading(socket), do: socket
end
