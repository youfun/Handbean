defmodule HandbeanWeb.WorkspaceLive.ConversationSearch do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  alias Handbean.Conversations
  alias HandbeanWeb.WorkspaceLive.ConversationRouting
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  @page_size 12

  def defaults(socket) do
    assign(socket, :conversation_search, %{
      open?: false,
      query: "",
      content: "all",
      range: "all",
      results: [],
      results_query: "",
      task_name: nil,
      next_cursor: nil,
      incomplete?: false,
      loading?: false,
      loaded?: false,
      revision: 0,
      error: nil
    })
  end

  def handle("open_conversation_search", _params, socket) do
    search = socket.assigns.conversation_search

    socket =
      socket
      |> WorkspaceNavigation.close_mobile_sheets()
      |> assign(:conversation_search, %{search | open?: true, error: nil})

    socket = if search.loaded?, do: socket, else: run_search(socket, nil)
    {:noreply, push_event(socket, "focus-conversation-search", %{})}
  end

  def handle("close_conversation_search", _params, socket) do
    search = socket.assigns.conversation_search

    {:noreply,
     socket
     |> assign(:conversation_search, %{search | open?: false, error: nil})
     |> push_event("restore-conversation-search-focus", %{})}
  end

  def handle("conversation_search", params, socket) do
    values = Map.get(params, "search", params)
    search = socket.assigns.conversation_search

    next = %{
      search
      | query: Map.get(values, "query", search.query),
        content: Map.get(values, "content", search.content),
        range: Map.get(values, "range", search.range),
        error: nil
    }

    {:noreply, socket |> assign(:conversation_search, next) |> run_search(nil)}
  end

  def handle("conversation_search_content", %{"content" => content}, socket) do
    search = socket.assigns.conversation_search

    {:noreply,
     socket |> assign(:conversation_search, %{search | content: content}) |> run_search(nil)}
  end

  def handle("load_more_conversation_search", _params, socket) do
    search = socket.assigns.conversation_search

    if not search.loading? and is_binary(search.next_cursor) do
      {:noreply, run_search(socket, search.next_cursor)}
    else
      {:noreply, socket}
    end
  end

  def handle("open_conversation_search_hit", params, socket) do
    conversation_id = params["conversation_id"]
    entry_id = present(params["entry_id"])
    scope = HandbeanWeb.Access.conversation_search_scope()

    with {:ok, target} <-
           Conversations.authorize_user_search_hit(scope, conversation_id, entry_id),
         {:ok, page} <- around_page(conversation_id, entry_id),
         {:ok, socket} <- switch_to_target(socket, target) do
      socket =
        if entry_id do
          ConversationState.load_around_history(socket, page, entry_id)
        else
          socket
        end

      search = socket.assigns.conversation_search
      path = conversation_path(target)

      socket =
        socket
        |> assign(:conversation_search, %{search | open?: false, error: nil})
        |> push_patch(to: path)

      socket =
        if entry_id,
          do: push_event(socket, "set-conversation-entry-hash", %{id: entry_id}),
          else: socket

      {:noreply, socket}
    else
      {:error, :entry_unavailable} ->
        {:noreply,
         put_search_error(socket, gettext("The matching message is no longer available."))}

      {:error, _reason} ->
        {:noreply, put_search_error(socket, gettext("This conversation is no longer available."))}
    end
  end

  def finish(socket, revision, append?, {:ok, result}) do
    search = socket.assigns.conversation_search

    if search.revision == revision do
      rows = add_workspace_labels(result.results, socket.assigns.workspaces)
      rows = if append?, do: merge_results(search.results, rows), else: rows

      assign(socket, :conversation_search, %{
        search
        | results: rows,
          results_query: search.query,
          task_name: nil,
          next_cursor: result.next_cursor,
          incomplete?: result.incomplete,
          loading?: false,
          loaded?: true,
          error: nil
      })
    else
      socket
    end
  end

  def finish(socket, revision, _append?, {:error, _reason}) do
    search = socket.assigns.conversation_search

    if search.revision == revision do
      assign(socket, :conversation_search, %{
        search
        | results: [],
          results_query: search.query,
          task_name: nil,
          next_cursor: nil,
          incomplete?: false,
          loading?: false,
          loaded?: true,
          error: gettext("Conversation search is temporarily unavailable.")
      })
    else
      socket
    end
  end

  def finish(socket, _revision, _append?, _result), do: socket

  defp run_search(socket, cursor) do
    search = socket.assigns.conversation_search

    input = %{
      "query" => search.query,
      "content" => search.content,
      "range" => search.range,
      "limit" => @page_size
    }

    input = if cursor, do: Map.put(input, "cursor", cursor), else: input
    scope = HandbeanWeb.Access.conversation_search_scope()
    revision = search.revision + 1
    append? = is_binary(cursor)

    task_name = {:conversation_search, revision, append?}

    socket =
      if search.task_name do
        cancel_async(socket, search.task_name)
      else
        socket
      end

    next_cursor = if append?, do: search.next_cursor, else: nil

    socket
    |> assign(:conversation_search, %{
      search
      | loading?: true,
        revision: revision,
        task_name: task_name,
        next_cursor: next_cursor,
        error: nil
    })
    |> start_async(task_name, fn ->
      Conversations.search_user_visible(input, scope)
    end)
  end

  defp merge_results(existing, incoming) do
    Enum.uniq_by(existing ++ incoming, & &1.conversation_id)
  end

  defp add_workspace_labels(results, workspaces) do
    labels = Map.new(workspaces, &{&1["id"], &1["name"]})

    Enum.map(results, fn result ->
      label =
        if result.scope == "free",
          do: gettext("Free chat"),
          else: Map.get(labels, result.workspace_id, gettext("Workspace"))

      Map.put(result, :workspace_label, label)
    end)
  end

  defp around_page(_conversation_id, nil), do: {:ok, nil}

  defp around_page(conversation_id, entry_id) do
    Handbean.ConversationTranscriptStore.page(conversation_id,
      around: entry_id,
      before_limit: 40,
      after_limit: 40
    )
  end

  defp switch_to_target(socket, %{scope: "free", conversation_id: conversation_id}) do
    socket = ConversationRouting.drop_composer_for_switch(socket, conversation_id)

    {socket, selected_id} =
      ConversationSwitching.select_free_conversation(socket, conversation_id)

    if selected_id == conversation_id do
      {:ok,
       socket
       |> WorkspaceNavigation.enter_free_chat()
       |> RuntimeProjection.subscribe_session()
       |> ConversationRouting.restore_session()
       |> WorkspaceNavigation.close_mobile_sheets()}
    else
      {:error, :not_accessible}
    end
  end

  defp switch_to_target(socket, %{
         scope: "workspace",
         workspace_id: workspace_id,
         conversation_id: conversation_id
       }) do
    socket = ConversationRouting.drop_composer_for_switch(socket, conversation_id)

    {socket, selected_id} =
      ConversationSwitching.select_conversation(socket, workspace_id, conversation_id)

    if selected_id == conversation_id do
      {:ok,
       socket
       |> WorkspaceNavigation.after_switch()
       |> RuntimeProjection.subscribe_session()
       |> ConversationRouting.restore_session()
       |> WorkspaceNavigation.close_mobile_sheets()}
    else
      {:error, :not_accessible}
    end
  end

  defp switch_to_target(_socket, _target), do: {:error, :not_accessible}

  defp conversation_path(%{scope: "free", conversation_id: conversation_id}),
    do: "/c/#{conversation_id}"

  defp conversation_path(%{workspace_id: workspace_id, conversation_id: conversation_id}),
    do: "/w/#{workspace_id}/c/#{conversation_id}"

  defp put_search_error(socket, message) do
    search = socket.assigns.conversation_search
    assign(socket, :conversation_search, %{search | error: message})
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
