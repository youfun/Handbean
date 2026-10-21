defmodule HandbeanWeb.WorkspaceLive.ScheduleEvents do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  alias HandbeanWeb.WorkspaceLive.ConversationRouting
  alias HandbeanWeb.WorkspaceLive.Schedules
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  def handle("toggle_schedules", _params, socket) do
    {:noreply,
     socket
     |> Schedules.toggle()
     |> WorkspaceNavigation.close_sheet_panels()}
  end

  def handle("schedule_request", %{"request" => request}, socket) do
    {:noreply, Schedules.remember_request(socket, request)}
  end

  def handle("schedule_ask", %{"request" => request}, socket) do
    case Schedules.prepare_ask(socket, request) do
      {:ok, socket, text} ->
        if socket.assigns.schedule_in_place do
          ConversationRouting.ask_schedule_in_place(socket, text)
        else
          ConversationRouting.ask_schedule_in_new_conversation(socket, text)
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle("schedule_select", %{"id" => id}, socket) do
    {:noreply, Schedules.select(socket, id)}
  end

  def handle("schedule_workspace", params, socket) do
    ws_id = Map.get(params, "workspace_id") || Map.get(params, "id")

    case ConversationRouting.switch_schedule_workspace(socket, ws_id) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle("schedule_filter", %{"filter" => filter}, socket) do
    {:noreply, Schedules.set_filter(socket, filter)}
  end

  def handle("schedule_search", params, socket) do
    {:noreply,
     Schedules.set_query(socket, Map.get(params, "query", Map.get(params, "value", "")))}
  end

  def handle("schedule_close_detail", _params, socket) do
    {:noreply, Schedules.close_detail(socket)}
  end

  def handle("schedule_instruction_toggle", _params, socket) do
    {:noreply, Schedules.toggle_instruction(socket)}
  end

  def handle("schedule_pause", %{"id" => id}, socket) do
    {:noreply, Schedules.pause(socket, id)}
  end

  def handle("schedule_resume", %{"id" => id}, socket) do
    {:noreply, Schedules.resume(socket, id)}
  end

  def handle("schedule_delete", %{"id" => id}, socket) do
    {:noreply, Schedules.delete(socket, id)}
  end

  def handle("schedule_run_now", %{"id" => id}, socket) do
    {:noreply, Schedules.run_now(socket, id)}
  end

  def handle("schedule_revise", %{"id" => id}, socket) do
    {:noreply, Schedules.revise(socket, id)}
  end

  def handle("open_schedule_conversation", %{"id" => conv_id, "ws_id" => ws_id}, socket) do
    case ConversationRouting.switch_workspace_conversation(socket, ws_id, conv_id) do
      {:ok, socket} -> {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
      {:error, socket} -> {:noreply, socket}
    end
  end
end
