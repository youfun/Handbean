defmodule HandbeanWeb.WorkspaceMemoryLive do
  @moduledoc "Workspace memory settings and browser embedded in the settings page."

  use HandbeanWeb, :live_view

  alias Handbean.Memory.MemoryStore
  alias Handbean.Utils.SafeMap
  alias Handbean.{WorkspaceSettings, WorkspaceStore}

  @kinds [:preference, :rule, :pattern, :fact, :context]
  @lifecycles [:active, :long_term, :short_term, :expired, :all]
  @scopes [:workspace, :both, :global]

  @impl true
  def mount(_params, session, socket) do
    workspaces = WorkspaceStore.list()

    workspace =
      Enum.find(workspaces, &(&1["id"] == session["workspace_id"])) || List.first(workspaces)

    socket =
      socket
      |> assign(:workspaces, workspaces)
      |> assign(:workspace, workspace)
      |> assign(:workspace_id, workspace && workspace["id"])
      |> assign(:scope_filter, if(workspace, do: :workspace, else: :global))
      |> assign(:lifecycle_filter, :active)
      |> assign(:kind_filter, :all)
      |> assign(:search_query, "")
      |> load_memory_setting()
      |> load_memories()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    socket =
      socket
      |> assign(:search_query, Map.get(params, "query", ""))
      |> assign(:scope_filter, normalize_filter(Map.get(params, "scope"), @scopes, :workspace))
      |> load_memories()

    {:noreply, socket}
  end

  def handle_event("set_lifecycle", %{"lifecycle" => lifecycle}, socket) do
    {:noreply,
     socket
     |> assign(:lifecycle_filter, normalize_filter(lifecycle, @lifecycles, :active))
     |> load_memories()}
  end

  def handle_event("set_kind", %{"kind" => kind}, socket) do
    {:noreply,
     socket
     |> assign(:kind_filter, normalize_filter(kind, [:all | @kinds], :all))
     |> load_memories()}
  end

  def handle_event("select_workspace", %{"workspace" => %{"id" => "global"}}, socket) do
    {:noreply,
     socket
     |> assign(:workspace, nil)
     |> assign(:workspace_id, nil)
     |> assign(:scope_filter, :global)
     |> load_memory_setting()
     |> load_memories()}
  end

  def handle_event("select_workspace", %{"workspace" => %{"id" => workspace_id}}, socket) do
    case Enum.find(socket.assigns.workspaces, &(&1["id"] == workspace_id)) do
      nil ->
        {:noreply, socket}

      workspace ->
        {:noreply,
         socket
         |> assign(:workspace, workspace)
         |> assign(:workspace_id, workspace_id)
         |> assign(:scope_filter, :workspace)
         |> load_memory_setting()
         |> load_memories()}
    end
  end

  def handle_event("toggle_builtin_memory", _params, %{assigns: %{workspace: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_builtin_memory", _params, socket) do
    enabled = !socket.assigns.builtin_memory_enabled
    path = socket.assigns.workspace["path"]

    case WorkspaceSettings.update_builtin_memory_enabled(path, enabled) do
      :ok ->
        {:noreply,
         assign(socket,
           builtin_memory_enabled: enabled,
           memory_setting_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :memory_setting_error, reason)}
    end
  end

  def handle_event("locate", %{"id" => id}, socket) do
    scope = if socket.assigns.workspace_id, do: :both, else: :global

    {:noreply,
     socket
     |> assign(:search_query, "##{id}")
     |> assign(:scope_filter, scope)
     |> assign(:lifecycle_filter, :all)
     |> assign(:kind_filter, :all)
     |> load_memories()}
  end

  def kind_filters, do: [:all | @kinds]

  def kind_label(:all), do: gettext("全部")
  def kind_label(:preference), do: gettext("偏好")
  def kind_label(:rule), do: gettext("规则")
  def kind_label(:pattern), do: gettext("模式")
  def kind_label(:fact), do: gettext("事实")
  def kind_label(:context), do: gettext("上下文")

  def lifecycle_cards(summary) do
    [
      {:active, gettext("有效记忆"), summary.active},
      {:long_term, gettext("长期记忆"), summary.long_term},
      {:short_term, gettext("短期记忆"), summary.short_term},
      {:expired, gettext("已过期"), summary.expired}
    ]
  end

  def kind_count(summary, :all), do: Enum.sum(Map.values(summary.by_kind))
  def kind_count(summary, kind), do: Map.get(summary.by_kind, kind, 0)

  def lifecycle_text(%{short_term: false, reinforced_count: count}, _now) when count > 0,
    do: gettext("长期 · 强化 ×%{count}", count: count)

  def lifecycle_text(%{short_term: false}, _now), do: gettext("长期")

  def lifecycle_text(%{short_term: true, expires_at: expires_at}, now) do
    seconds = DateTime.diff(expires_at, now, :second)

    if seconds <= 0 do
      gettext("已过期")
    else
      hours = max(1, div(seconds + 3599, 3600))
      gettext("短期 · %{hours}h 后过期", hours: hours)
    end
  end

  def lifecycle_text(engram), do: lifecycle_text(engram, DateTime.utc_now())

  def expired?(%{short_term: true, expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  def expired?(_engram, _now), do: false

  def global?(engram), do: SafeMap.get(engram.metadata || %{}, "scope") == "global"

  def format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  def format_date(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  def format_date(_datetime), do: ""

  def format_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def format_iso(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  def format_iso(_datetime), do: ""

  def associations(engram) do
    outgoing =
      Enum.map(engram.source_synapses, fn synapse ->
        %{id: synapse.target_id, kind: synapse.kind, direction: "↳"}
      end)

    incoming =
      Enum.map(engram.target_synapses, fn synapse ->
        %{id: synapse.source_id, kind: synapse.kind, direction: "↰"}
      end)

    outgoing ++ incoming
  end

  defp load_memory_setting(%{assigns: %{workspace: nil}} = socket) do
    assign(socket,
      builtin_memory_enabled: nil,
      memory_setting_error: nil
    )
  end

  defp load_memory_setting(socket) do
    path = socket.assigns.workspace["path"]

    case WorkspaceSettings.load(path) do
      {:ok, settings} ->
        assign(socket,
          builtin_memory_enabled:
            WorkspaceSettings.builtin_memory_enabled_from_settings(settings),
          memory_setting_error: nil
        )

      {:error, reason} ->
        assign(socket,
          builtin_memory_enabled: false,
          memory_setting_error: reason
        )
    end
  end

  defp load_memories(socket) do
    opts =
      [
        workspace_id: socket.assigns.workspace_id,
        scope: socket.assigns.scope_filter,
        lifecycle: socket.assigns.lifecycle_filter,
        query: socket.assigns.search_query
      ]
      |> maybe_put_kind(socket.assigns.kind_filter)

    summary_opts =
      opts
      |> Keyword.delete(:workspace_id)
      |> Keyword.delete(:kind)

    assign(socket,
      memories: MemoryStore.list_engrams(opts),
      summary: MemoryStore.count_summary(socket.assigns.workspace_id, summary_opts),
      now: DateTime.utc_now()
    )
  end

  defp maybe_put_kind(opts, :all), do: opts
  defp maybe_put_kind(opts, kind), do: Keyword.put(opts, :kind, kind)

  defp normalize_filter(value, allowed, fallback) when is_binary(value) do
    Enum.find(allowed, fallback, &(Atom.to_string(&1) == value))
  end

  defp normalize_filter(value, allowed, fallback) do
    if value in allowed, do: value, else: fallback
  end
end
