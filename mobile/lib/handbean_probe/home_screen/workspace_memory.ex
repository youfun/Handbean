defmodule HandbeanProbe.HomeScreen.WorkspaceMemory do
  @moduledoc "HomeScreen controller for asynchronous workspace-memory browsing."

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 3]

  alias HandbeanProbe.HomeScreen.{Async, Notice, Requests}
  alias HandbeanProbe.{NativeClipboard, WorkspaceMemory}

  @scope :workspace_memory

  def load(%{assigns: %{workspace: nil}} = socket), do: socket

  def load(socket) do
    state =
      socket.assigns.workspace_memory
      |> WorkspaceMemory.load_builtin_memory(socket.assigns.workspace["path"])
      |> WorkspaceMemory.load_privacy_mode(socket.assigns.workspace["path"])
      |> WorkspaceMemory.loading()

    workspace_id = socket.assigns.workspace["id"]
    {_generation, socket} = Requests.bump(socket, @scope)

    socket
    |> assign(:workspace_memory, state)
    |> Async.run(
      :workspace_memory_loaded,
      fn -> safely_fetch(workspace_id, state) end,
      scope: @scope,
      bump?: false
    )
  end

  def handle(_event, %{assigns: %{workspace_memory: %{busy?: true}}} = socket), do: socket

  def handle({:change, :memory_query, query}, socket) do
    reload(socket, WorkspaceMemory.set_query(socket.assigns.workspace_memory, query))
  end

  def handle({:change, :memory_builtin, enabled}, socket) when is_boolean(enabled) do
    handle({:tap, {:memory_builtin, enabled}}, socket)
  end

  def handle({:tap, {:memory_builtin, enabled}}, socket) when is_boolean(enabled) do
    path = socket.assigns.workspace["path"]

    case Handbean.WorkspaceSettings.update_builtin_memory_enabled(path, enabled) do
      :ok ->
        assign(
          socket,
          :workspace_memory,
          WorkspaceMemory.set_builtin_memory(socket.assigns.workspace_memory, enabled)
        )

      {:error, _reason} ->
        Notice.put_error(socket, gettext("Could not save workspace memory setting"))
    end
  end

  def handle({:tap, {:toggle_select, id}}, socket) when is_binary(id) do
    put(socket, WorkspaceMemory.toggle_select(socket.assigns.workspace_memory, id))
  end

  def handle({:tap, {:memory_scope, scope}}, socket) do
    reload(socket, WorkspaceMemory.set_scope(socket.assigns.workspace_memory, scope))
  end

  def handle({:tap, {:memory_lifecycle, lifecycle}}, socket) do
    reload(socket, WorkspaceMemory.set_lifecycle(socket.assigns.workspace_memory, lifecycle))
  end

  def handle({:tap, {:memory_kind, kind}}, socket) do
    reload(socket, WorkspaceMemory.set_kind(socket.assigns.workspace_memory, kind))
  end

  def handle({:tap, {:memory_related, id}}, socket) do
    reload(socket, WorkspaceMemory.locate(socket.assigns.workspace_memory, id))
  end

  def handle({:change, :memory_edit_content, content}, socket) do
    put(socket, WorkspaceMemory.set_edit_content(socket.assigns.workspace_memory, content))
  end

  def handle({:tap, {:memory_edit_kind, kind}}, socket) do
    put(socket, WorkspaceMemory.set_edit_kind(socket.assigns.workspace_memory, kind))
  end

  def handle({:tap, {:memory_edit, id}}, socket) do
    put(socket, WorkspaceMemory.edit(socket.assigns.workspace_memory, id))
  end

  def handle({:tap, :memory_cancel_edit}, socket) do
    put(socket, WorkspaceMemory.cancel_edit(socket.assigns.workspace_memory))
  end

  def handle({:tap, {:memory_promote, id}}, socket) do
    mutate(socket, :promote, fn workspace_id, state ->
      WorkspaceMemory.promote(workspace_id, state, id)
    end)
  end

  def handle({:tap, :memory_save_edit}, socket) do
    mutate(socket, :update, &WorkspaceMemory.save_edit/2)
  end

  def handle({:tap, {:memory_ask_delete, id}}, socket) do
    put(socket, WorkspaceMemory.confirm_delete(socket.assigns.workspace_memory, id))
  end

  def handle({kind, :memory_dismiss_confirm}, socket) when kind in [:tap, :dismiss] do
    put(socket, WorkspaceMemory.dismiss_delete(socket.assigns.workspace_memory))
  end

  def handle({:tap, :memory_delete}, socket) do
    mutate(socket, :delete, &WorkspaceMemory.delete/2)
  end

  def handle({:tap, {:memory_copy, field, id}}, socket) when field in [:id, :content] do
    case WorkspaceMemory.copy_value(socket.assigns.workspace_memory, id, field) do
      {:ok, value} ->
        socket
        |> NativeClipboard.put(value)
        |> Notice.put_info(copied_notice(field))

      :error ->
        socket
    end
  end

  def handle(_event, socket), do: socket

  def result(result, socket) do
    assign(
      socket,
      :workspace_memory,
      WorkspaceMemory.loaded(socket.assigns.workspace_memory, result)
    )
  end

  def mutation_result({action, result}, socket) do
    if mutation_success?(result) do
      state = WorkspaceMemory.mutation_succeeded(socket.assigns.workspace_memory)

      socket
      |> put(state)
      |> Notice.put_info(success_notice(action))
      |> load()
    else
      reason = mutation_error(result)
      state = WorkspaceMemory.mutation_failed(socket.assigns.workspace_memory, reason)

      socket
      |> put(state)
      |> Notice.put_error(failure_notice(action))
    end
  end

  def mutation_result(_result, socket) do
    state = WorkspaceMemory.mutation_failed(socket.assigns.workspace_memory, :invalid_result)
    socket |> put(state) |> Notice.put_error(gettext("Could not update memory"))
  end

  defp mutate(socket, action, fun) do
    state = socket.assigns.workspace_memory
    workspace_id = socket.assigns.workspace["id"]
    {_generation, socket} = Requests.bump(socket, @scope)

    socket
    |> put(WorkspaceMemory.mutating(state))
    |> Async.run(
      :workspace_memory_mutated,
      fn -> {action, safely_mutate(fun, workspace_id, state)} end,
      scope: @scope,
      bump?: false
    )
  end

  defp safely_fetch(workspace_id, state) do
    WorkspaceMemory.fetch(workspace_id, state)
  rescue
    _ -> {:error, :operation_failed}
  catch
    :exit, _ -> {:error, :operation_failed}
  end

  defp safely_mutate(fun, workspace_id, state) do
    fun.(workspace_id, state)
  rescue
    _ -> {:error, :operation_failed}
  catch
    :exit, _ -> {:error, :operation_failed}
  end

  defp mutation_success?(:ok), do: true
  defp mutation_success?({:ok, _value}), do: true
  defp mutation_success?(_result), do: false

  defp mutation_error({:error, reason}), do: reason
  defp mutation_error(other), do: other

  defp reload(socket, state) do
    socket
    |> put(state)
    |> load()
  end

  defp put(socket, state), do: assign(socket, :workspace_memory, state)

  defp success_notice(:promote), do: gettext("Memory promoted")
  defp success_notice(:update), do: gettext("Memory updated")
  defp success_notice(:delete), do: gettext("Memory deleted")

  defp failure_notice(:promote), do: gettext("Could not promote memory")
  defp failure_notice(:update), do: gettext("Could not update memory")
  defp failure_notice(:delete), do: gettext("Could not delete memory")

  defp copied_notice(:id), do: gettext("Memory ID copied")
  defp copied_notice(:content), do: gettext("Memory content copied")
end
