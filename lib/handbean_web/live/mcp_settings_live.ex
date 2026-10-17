defmodule HandbeanWeb.MCPSettingsLive do
  @moduledoc "MCP server settings, embedded in the main settings page."

  use HandbeanWeb, :live_view

  alias Handbean.MCP.Settings
  alias Handbean.WorkspaceStore

  @impl true
  def mount(_params, session, socket) do
    workspace_id = session["workspace_id"]

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:workspaces, WorkspaceStore.list())
      |> assign(:servers, [])
      |> assign(:load_error, nil)
      |> assign(:form, nil)
      |> assign(:form_error, nil)
      |> assign(:editing_transport, nil)
      |> assign(:testing, false)
      |> assign(:test_result, nil)
      |> assign(:test_generation, 0)
      |> assign(:delete_target, nil)
      |> load_servers()

    {:ok, socket}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_transport, :http)
     |> open_form(Settings.new_form(socket.assigns.workspace_id))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Settings.edit(id) do
      {:ok, form} ->
        transport =
          case Enum.find(socket.assigns.servers, &(&1.id == id)) do
            nil -> :http
            server -> server.transport
          end

        {:noreply, socket |> assign(:editing_transport, transport) |> open_form(form)}

      {:error, reason} ->
        {:noreply, assign(socket, :load_error, reason)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:form, nil) |> assign(:form_error, nil) |> invalidate_test()}
  end

  def handle_event("change", %{"server" => params}, socket) do
    form = merge_form(socket.assigns.form, params)
    {:noreply, socket |> assign(:form, form) |> assign(:form_error, nil) |> invalidate_test()}
  end

  def handle_event("save", %{"server" => params}, socket) do
    form = merge_form(socket.assigns.form, params)

    case Settings.save(form) do
      {:ok, _id} ->
        {:noreply, socket |> assign(:form, nil) |> assign(:form_error, nil) |> load_servers()}

      {:error, reason} ->
        {:noreply, socket |> assign(:form, form) |> assign(:form_error, reason)}
    end
  end

  def handle_event("test_connection", _params, socket) do
    form = socket.assigns.form
    generation = socket.assigns.test_generation + 1

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:testing, true)
     |> assign(:test_result, nil)
     |> assign(:test_generation, generation)
     |> start_async({:test_connection, generation}, fn ->
       {generation, Settings.test_connection(form)}
     end)}
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :delete_target, id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Settings.delete(id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:delete_target, nil)
         |> then(fn socket ->
           if socket.assigns.form && socket.assigns.form["id"] == id,
             do: assign(socket, :form, nil),
             else: socket
         end)
         |> load_servers()}

      {:error, reason} ->
        {:noreply, socket |> assign(:delete_target, nil) |> assign(:load_error, reason)}
    end
  end

  @impl true
  def handle_async({:test_connection, generation}, {:ok, {generation, result}}, socket) do
    if generation == socket.assigns.test_generation do
      {:noreply, socket |> assign(:testing, false) |> assign(:test_result, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:test_connection, generation}, {:exit, _reason}, socket) do
    if generation == socket.assigns.test_generation do
      {:noreply,
       socket
       |> assign(:testing, false)
       |> assign(:test_result, {:error, "Connection test failed or timed out"})}
    else
      {:noreply, socket}
    end
  end

  defp load_servers(socket) do
    case Settings.list() do
      {:ok, servers} -> assign(socket, servers: servers, load_error: nil)
      {:error, reason} -> assign(socket, servers: [], load_error: reason)
    end
  end

  defp open_form(socket, form) do
    socket
    |> assign(:form, form)
    |> assign(:form_error, nil)
    |> assign(:delete_target, nil)
    |> invalidate_test()
  end

  defp invalidate_test(socket) do
    assign(socket,
      testing: false,
      test_result: nil,
      test_generation: socket.assigns.test_generation + 1
    )
  end

  defp merge_form(form, params) do
    params =
      params
      |> Map.put("disabled", Map.get(params, "disabled", "false") in ["true", "on"])
      |> Map.put("workspace_ids", Map.get(params, "workspace_ids", []) |> List.wrap())

    Map.merge(form, params)
  end
end
