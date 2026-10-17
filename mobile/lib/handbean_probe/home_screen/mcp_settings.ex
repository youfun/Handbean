defmodule HandbeanProbe.HomeScreen.MCPSettings do
  @moduledoc "HomeScreen controller for asynchronous MCP persistence and connection tests."
  import Mob.Socket, only: [assign: 3]
  alias HandbeanProbe.{MCPSettings, HomeScreen.Async}
  alias HandbeanProbe.HomeScreen.Requests

  @scope :mcp_settings

  def load(socket) do
    socket
    |> assign(:mcp, %{socket.assigns.mcp | loading?: true, error: nil})
    |> run(:mcp_loaded, fn -> Handbean.MCP.Settings.list() end)
  end

  def handle(_event, %{assigns: %{mcp: %{busy?: true}}} = socket), do: socket

  def handle({:change, {:mcp_field, field}, value}, socket),
    do: change(socket, MCPSettings.change(socket.assigns.mcp, field, value))

  def handle({:tap, {:mcp_auth, value}}, socket),
    do: change(socket, MCPSettings.change(socket.assigns.mcp, :auth, value))

  def handle({:tap, {:mcp_access, value}}, socket),
    do: change(socket, MCPSettings.change(socket.assigns.mcp, :access_mode, value))

  def handle({:tap, {:mcp_workspace, id}}, socket),
    do: change(socket, MCPSettings.toggle_workspace(socket.assigns.mcp, id))

  def handle({:tap, :mcp_toggle_disabled}, socket),
    do: change(socket, MCPSettings.toggle_disabled(socket.assigns.mcp))

  def handle({:tap, :mcp_add}, socket),
    do: change(socket, MCPSettings.open_new(socket.assigns.mcp, socket.assigns.workspace["id"]))

  def handle({:tap, {:mcp_edit, id}}, socket),
    do: run(socket, :mcp_edited, fn -> Handbean.MCP.Settings.edit(id) end)

  def handle({:tap, :mcp_save}, socket),
    do: run(socket, :mcp_saved, fn -> Handbean.MCP.Settings.save(socket.assigns.mcp.form) end)

  def handle({:tap, :mcp_test}, %{assigns: %{mcp: %{testing?: true}}} = socket), do: socket

  def handle({:tap, :mcp_test}, socket) do
    socket
    |> assign(:mcp, %{socket.assigns.mcp | testing?: true, error: nil, test_result: nil})
    |> run(:mcp_tested, fn -> Handbean.MCP.Settings.test_connection(socket.assigns.mcp.form) end)
  end

  def handle({:tap, :mcp_cancel}, socket) do
    if MCPSettings.dirty?(socket.assigns.mcp),
      do: put(socket, %{socket.assigns.mcp | confirm: :discard}),
      else: close(socket)
  end

  def handle({:tap, :mcp_ask_delete}, socket),
    do: put(socket, %{socket.assigns.mcp | confirm: :delete})

  def handle({:tap, :mcp_dismiss_confirm}, socket),
    do: put(socket, %{socket.assigns.mcp | confirm: nil})

  def handle({:dismiss, :mcp_dismiss_confirm}, socket),
    do: handle({:tap, :mcp_dismiss_confirm}, socket)

  def handle({:tap, :mcp_discard}, socket), do: close(socket)

  def handle({:tap, :mcp_delete}, socket),
    do:
      run(socket, :mcp_deleted, fn ->
        Handbean.MCP.Settings.delete(socket.assigns.mcp.form["id"])
      end)

  def result(kind, result, socket) do
    socket = put(socket, %{socket.assigns.mcp | busy?: false})
    apply_result(kind, result, socket)
  end

  defp apply_result(:mcp_loaded, result, socket),
    do: put(socket, MCPSettings.loaded(socket.assigns.mcp, result))

  defp apply_result(:mcp_edited, result, socket),
    do: put(socket, MCPSettings.open_edit(socket.assigns.mcp, result))

  defp apply_result(:mcp_tested, result, socket),
    do: put(socket, MCPSettings.tested(socket.assigns.mcp, result))

  defp apply_result(:mcp_saved, result, socket) do
    state = MCPSettings.saved(socket.assigns.mcp, result)
    if match?({:ok, _}, result), do: socket |> put(state) |> load(), else: put(socket, state)
  end

  defp apply_result(:mcp_deleted, :ok, socket), do: socket |> close() |> load()

  defp apply_result(:mcp_deleted, {:error, reason}, socket),
    do: put(socket, %{socket.assigns.mcp | confirm: nil, error: to_string(reason)})

  defp run(socket, kind, fun) do
    {_generation, socket} = Requests.bump(socket, @scope)
    socket = put(socket, %{socket.assigns.mcp | busy?: kind != :mcp_tested})

    Async.run(
      socket,
      kind,
      fn ->
        try do
          fun.()
        rescue
          _ -> {:error, "MCP settings operation failed"}
        catch
          :exit, _ -> {:error, "MCP settings operation timed out or failed"}
        end
      end, scope: @scope)
  end

  defp put(socket, state), do: assign(socket, :mcp, state)

  defp change(socket, state) do
    {_generation, socket} = Requests.bump(socket, @scope)
    put(socket, %{state | testing?: false, test_result: nil, loading?: false})
  end

  defp close(socket) do
    {_generation, socket} = Requests.bump(socket, @scope)

    put(socket, %{
      socket.assigns.mcp
      | form: nil,
        original: nil,
        confirm: nil,
        error: nil,
        test_result: nil,
        testing?: false
    })
  end
end
