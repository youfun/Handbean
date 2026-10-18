defmodule HandbeanWeb.FileBrowserComponent do
  @moduledoc """
  Server-side file browser LiveComponent.

  Allows users to browse server directories and select a folder.
  Directory-only view — files are hidden.

  Hidden directories are omitted by default:
    - names beginning with `.` (dot folders)
    - node_modules, _build, deps
  """

  use HandbeanWeb, :live_component

  @hidden_dirs ~w(node_modules _build deps)

  @impl true
  def update(assigns, socket) do
    current_path =
      if is_binary(assigns[:current_path]) and assigns[:current_path] != "" and
           File.dir?(assigns[:current_path]) do
        Path.expand(assigns[:current_path])
      else
        Handbean.Home.path()
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:current_path, current_path)
     |> assign(:show_browser, Map.get(assigns, :show_browser, false))
     |> assign(:error, nil)
     |> load_directory(current_path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="file-browser-root">
      <div
        :if={@show_browser}
        id="file-browser-overlay"
        class="fixed inset-0 z-50 flex items-center justify-center"
        phx-click="close_browser"
        phx-target={@myself}
      >
        <div
          id="file-browser-dialog"
          class="relative bg-surface border rounded-xl shadow-2xl max-w-2xl w-full mx-4 flex flex-col"
          style="max-height: 80vh;"
          phx-click="stop_propagation"
        >
          <!-- Header -->
          <div class="border-b p-4">
            <h3 class="text-base font-semibold text-primary">{gettext("选择文件夹")}</h3>
            <p class="text-xs text-tertiary mt-1">{gettext("浏览并选择项目文件夹")}</p>
          </div>

          <!-- Current Path -->
          <div class="border-b px-4 py-3">
            <div class="flex items-center gap-2">
              <span class="text-xs text-tertiary">{gettext("位置:")}</span>
              <code class="text-xs font-mono bg-main px-2 py-1 rounded flex-1 truncate text-primary">
                {@current_path}
              </code>
              <button
                type="button"
                phx-click="go_home"
                phx-target={@myself}
                class="text-xs text-secondary border rounded px-2 py-1 transition-colors hover:text-primary hover:border-hover"
                title={gettext("返回主目录")}
              >
                /~home
              </button>
            </div>
          </div>

          <!-- Directory List -->
          <div class="flex-1 overflow-y-auto p-4 space-y-1">
            <!-- Error -->
            <div
              :if={@error}
              class="text-sm text-error p-3 bg-error-subtle rounded-md mb-2"
            >
              {render_error(@error)}
            </div>

            <!-- Parent Directory -->
            <button
              :if={@current_path != "/"}
              type="button"
              phx-click="navigate_up"
              phx-target={@myself}
              class="w-full flex items-center gap-3 px-3 py-2 rounded text-left text-sm transition-colors hover:bg-surface-hover"
            >
              <span class="text-base">📁</span>
              <div class="flex-1">
                <div class="font-medium text-primary">..</div>
                <div class="text-xs text-tertiary">{gettext("上级目录")}</div>
              </div>
            </button>

            <!-- Directories -->
            <button
              :for={dir <- @directories}
              type="button"
              phx-click="navigate_to"
              phx-target={@myself}
              phx-value-path={dir.path}
              class="w-full flex items-center gap-3 px-3 py-2 rounded text-left text-sm transition-colors hover:bg-surface-hover group"
            >
              <span class="text-base">📁</span>
              <div class="flex-1 min-w-0">
                <div class="font-medium text-primary truncate group-hover:text-accent">
                  {dir.name}
                </div>
              </div>
              <span class="text-tertiary text-xs group-hover:text-secondary">→</span>
            </button>

            <!-- Empty State -->
            <div
              :if={Enum.empty?(@directories) and not @error}
              class="text-center py-8"
            >
              <div class="text-3xl mb-2 opacity-40">📂</div>
              <div class="text-xs text-tertiary">{gettext("此目录下没有可用的子文件夹")}</div>
            </div>
          </div>

          <!-- Footer -->
          <div class="border-t px-4 py-3 flex justify-between items-center">
            <div class="text-xs text-tertiary">
              {ngettext("1 folder", "%{count} folders", length(@directories))}
            </div>
            <div class="flex gap-3">
              <button
                type="button"
                phx-click="close_browser"
                phx-target={@myself}
                class="text-sm text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
              >
                {gettext("取消")}
              </button>
              <button
                type="button"
                phx-click="select_current"
                phx-target={@myself}
                class="text-sm bg-user text-white rounded px-3 py-1.5 transition-colors hover:bg-user-hover"
              >
                {gettext("选择当前目录")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("close_browser", _params, socket) do
    send(self(), {:file_browser_closed})
    {:noreply, assign(socket, :show_browser, false)}
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to", %{"path" => path}, socket) do
    {:noreply, load_directory(socket, path)}
  end

  def handle_event("navigate_up", _params, socket) do
    parent = Path.expand("..", socket.assigns.current_path)
    {:noreply, load_directory(socket, parent)}
  end

  def handle_event("go_home", _params, socket) do
    {:noreply, load_directory(socket, Handbean.Home.path())}
  end

  def handle_event("select_current", _params, socket) do
    send(self(), {:folder_selected_from_browser, socket.assigns.current_path})
    {:noreply, assign(socket, :show_browser, false)}
  end

  # ── Private ──

  defp load_directory(socket, path) do
    case File.ls(path) do
      {:ok, entries} ->
        directories =
          entries
          |> Enum.filter(fn name ->
            full_path = Path.join(path, name)
            File.dir?(full_path) and visible_directory?(name)
          end)
          |> Enum.map(fn name ->
            %{name: name, path: Path.join(path, name)}
          end)
          |> Enum.sort_by(& &1.name)

        socket
        |> assign(:current_path, path)
        |> assign(:directories, directories)
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:directories, [])
        |> assign(:error, "无法访问目录: #{inspect(reason)}")
    end
  end

  defp visible_directory?(name) do
    not String.starts_with?(name, ".") and name not in @hidden_dirs
  end

  defp render_error(msg) when is_binary(msg), do: msg
  defp render_error(msg), do: inspect(msg)
end
