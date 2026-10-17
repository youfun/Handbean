defmodule HandbeanProbe.WorkspaceMemory do
  @moduledoc "Native workspace memory settings and browser."

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias Handbean.Memory.MemoryStore
  alias Handbean.Utils.SafeMap

  @kinds [:preference, :rule, :pattern, :fact, :context]
  @lifecycles [:active, :long_term, :short_term, :expired, :all]
  @scopes [:workspace, :both, :global]

  defstruct items: [],
            summary: %{
              active: 0,
              long_term: 0,
              short_term: 0,
              expired: 0,
              by_kind: %{}
            },
            scope: :workspace,
            lifecycle: :active,
            kind: :all,
            query: "",
            builtin_memory_enabled: true,
            now: nil,
            loading?: false,
            error: nil

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec fetch(String.t(), t()) :: {:ok, map()}
  def fetch(workspace_id, %__MODULE__{} = state) when is_binary(workspace_id) do
    opts =
      [
        workspace_id: workspace_id,
        scope: state.scope,
        lifecycle: state.lifecycle,
        query: state.query
      ]
      |> maybe_put_kind(state.kind)

    summary_opts = opts |> Keyword.delete(:workspace_id) |> Keyword.delete(:kind)

    {:ok,
     %{
       items: MemoryStore.list_engrams(opts),
       summary: MemoryStore.count_summary(workspace_id, summary_opts),
       now: DateTime.utc_now()
     }}
  end

  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = state), do: %{state | loading?: true, error: nil}

  @spec loaded(t(), {:ok, map()} | {:error, term()}) :: t()
  def loaded(%__MODULE__{} = state, {:ok, result}) do
    %{
      state
      | items: result.items,
        summary: result.summary,
        now: result.now,
        loading?: false,
        error: nil
    }
  end

  def loaded(%__MODULE__{} = state, {:error, reason}) do
    %{state | loading?: false, error: to_string(reason)}
  end

  def set_query(%__MODULE__{} = state, query) when is_binary(query), do: %{state | query: query}
  def set_query(%__MODULE__{} = state, _query), do: state

  def set_scope(%__MODULE__{} = state, scope) when scope in @scopes,
    do: %{state | scope: scope}

  def set_scope(%__MODULE__{} = state, _scope), do: state

  def set_lifecycle(%__MODULE__{} = state, lifecycle) when lifecycle in @lifecycles,
    do: %{state | lifecycle: lifecycle}

  def set_lifecycle(%__MODULE__{} = state, _lifecycle), do: state

  def set_kind(%__MODULE__{} = state, kind) when kind in [:all | @kinds],
    do: %{state | kind: kind}

  def set_kind(%__MODULE__{} = state, _kind), do: state

  def load_builtin_memory(%__MODULE__{} = state, workspace_path) do
    %{
      state
      | builtin_memory_enabled: Handbean.WorkspaceSettings.builtin_memory_enabled(workspace_path)
    }
  end

  def set_builtin_memory(%__MODULE__{} = state, enabled) when is_boolean(enabled),
    do: %{state | builtin_memory_enabled: enabled}

  def locate(%__MODULE__{} = state, id) when is_integer(id) do
    %{state | query: "##{id}", scope: :both, lifecycle: :all, kind: :all}
  end

  def locate(%__MODULE__{} = state, _id), do: state

  def copy_value(%__MODULE__{} = state, id, :id) when is_integer(id) do
    if Enum.any?(state.items, &(&1.id == id)), do: {:ok, "##{id}"}, else: :error
  end

  def copy_value(%__MODULE__{} = state, id, :content) when is_integer(id) do
    case Enum.find(state.items, &(&1.id == id)) do
      nil -> :error
      item -> {:ok, item.content}
    end
  end

  def copy_value(%__MODULE__{}, _id, _field), do: :error

  @spec render(t(), map()) :: Mob.Node.t()
  def render(%__MODULE__{} = state, workspace) do
    scroll(
      [
        workspace_card(workspace),
        builtin_memory_card(state),
        lifecycle_grid(state),
        filters(state),
        status_node(state)
      ] ++ memory_cards(state),
      id: "workspace-memory"
    )
  end

  defp workspace_card(workspace) do
    name = (workspace && workspace["name"]) || gettext("Workspace")
    path = (workspace && workspace["path"]) || ""

    card([
      text(gettext("Workspace Memory"), text_size: 17, font_weight: "bold"),
      text(gettext("Current workspace: %{name}", name: name),
        text_size: 13,
        text_color: color(:muted),
        padding_top: 8
      ),
      text(path, text_size: 12, text_color: color(:hint), padding_top: 4)
    ])
  end

  defp builtin_memory_card(state) do
    card([
      text(gettext("Use built-in memory"), text_size: 15, font_weight: "bold"),
      text(
        gettext("External memory tools remain available when built-in memory is off."),
        text_size: 12,
        text_color: color(:muted),
        padding_top: 6,
        padding_bottom: 8
      ),
      segment_row([
        segment_button(
          gettext("On"),
          {:memory_builtin, true},
          state.builtin_memory_enabled
        ),
        segment_button(
          gettext("Off"),
          {:memory_builtin, false},
          not state.builtin_memory_enabled
        )
      ])
    ])
  end

  defp lifecycle_grid(state) do
    [first, second, third, fourth] = lifecycle_cards(state.summary)

    card([
      segment_row(Enum.map([first, second], &lifecycle_button(&1, state.lifecycle))),
      segment_row(Enum.map([third, fourth], &lifecycle_button(&1, state.lifecycle)),
        padding_top: 8
      )
    ])
  end

  defp lifecycle_cards(summary) do
    [
      {:active, gettext("Active memory"), summary.active},
      {:long_term, gettext("Long-term memory"), summary.long_term},
      {:short_term, gettext("Short-term memory"), summary.short_term},
      {:expired, gettext("Expired"), summary.expired}
    ]
  end

  defp lifecycle_button({lifecycle, label, count}, selected) do
    segment_button("#{label}  #{count}", {:memory_lifecycle, lifecycle}, lifecycle == selected)
  end

  defp filters(state) do
    kinds = [:all | @kinds]
    {first, second} = Enum.split(kinds, 3)

    card([
      field(gettext("Search"), state.query, :memory_query,
        placeholder: gettext("Search content or #ID…")
      ),
      text(gettext("Scope"), text_size: 13, text_color: color(:muted), padding_bottom: 6),
      segment_row(
        Enum.map(@scopes, fn scope ->
          segment_button(scope_label(scope), {:memory_scope, scope}, state.scope == scope)
        end)
      ),
      text(gettext("Type"),
        text_size: 13,
        text_color: color(:muted),
        padding_top: 12,
        padding_bottom: 6
      ),
      segment_row(Enum.map(first, &kind_button(&1, state))),
      segment_row(Enum.map(second, &kind_button(&1, state)), padding_top: 8)
    ])
  end

  defp kind_button(kind, state) do
    count = kind_count(state.summary, kind)
    segment_button("#{kind_label(kind)}  #{count}", {:memory_kind, kind}, state.kind == kind)
  end

  defp kind_count(summary, :all), do: Enum.sum(Map.values(summary.by_kind))
  defp kind_count(summary, kind), do: Map.get(summary.by_kind, kind, 0)

  defp status_node(%{loading?: true}),
    do: text(gettext("Loading memory…"), text_color: color(:muted), padding_bottom: 12)

  defp status_node(%{error: error}) when is_binary(error),
    do: text(error, text_color: color(:danger), padding_bottom: 12)

  defp status_node(_state), do: nil

  defp memory_cards(%{items: [], loading?: false, error: nil}) do
    [
      card([
        text(gettext("No memories match these filters"), text_size: 15),
        text(gettext("Try another scope, lifecycle, type, or search."),
          text_size: 13,
          text_color: color(:muted),
          padding_top: 8
        )
      ])
    ]
  end

  defp memory_cards(state), do: Enum.map(state.items, &memory_card(&1, state.now))

  defp memory_card(engram, now) do
    expired = expired?(engram, now)
    ink = if(expired, do: color(:hint), else: color(:ink))

    card(
      [
        row([
          text("##{engram.id}", font_weight: "bold", text_color: ink),
          gap(8),
          text(kind_badge(engram.kind), text_size: 12, text_color: ink),
          if(global?(engram), do: text(gettext("Global"), text_size: 12, text_color: ink)),
          text(format_date(engram.updated_at || engram.inserted_at),
            weight: 1,
            text_align: "right",
            text_size: 12,
            text_color: color(:hint)
          )
        ]),
        text(lifecycle_text(engram, now),
          text_size: 12,
          text_color: if(expired, do: color(:danger), else: color(:muted)),
          padding_top: 6
        ),
        text(engram.content, text_color: ink, padding_top: 12),
        association_nodes(engram),
        actions_row([
          secondary_button(gettext("Copy #ID"), {:memory_copy, :id, engram.id}),
          secondary_button(gettext("Copy content"), {:memory_copy, :content, engram.id})
        ])
      ]
      |> List.flatten(),
      background: if(expired, do: color(:control), else: color(:card))
    )
  end

  defp association_nodes(engram) do
    case associations(engram) do
      [] ->
        []

      associations ->
        [
          text(gettext("Connections"),
            text_size: 12,
            text_color: color(:muted),
            padding_top: 12,
            padding_bottom: 4
          )
          | Enum.map(associations, fn association ->
              list_row(
                "#{association.direction} #{association.kind} ##{association.id}",
                {:memory_related, association.id},
                text_size: 12,
                padding: 8
              )
            end)
        ]
    end
  end

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

  def lifecycle_text(%{short_term: false, reinforced_count: count}, _now) when count > 0,
    do: gettext("Long-term · reinforced ×%{count}", count: count)

  def lifecycle_text(%{short_term: false}, _now), do: gettext("Long-term")

  def lifecycle_text(%{short_term: true, expires_at: expires_at}, now)
      when not is_nil(expires_at) and not is_nil(now) do
    seconds = DateTime.diff(expires_at, now, :second)

    if seconds <= 0 do
      gettext("Expired")
    else
      hours = max(1, div(seconds + 3599, 3600))
      gettext("Short-term · expires in %{hours}h", hours: hours)
    end
  end

  def lifecycle_text(%{short_term: true}, _now), do: gettext("Short-term")

  def expired?(%{short_term: true, expires_at: %DateTime{} = expires_at}, %DateTime{} = now),
    do: DateTime.compare(expires_at, now) != :gt

  def expired?(_engram, _now), do: false

  defp global?(engram), do: SafeMap.get(engram.metadata || %{}, "scope") == "global"

  defp format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  defp format_date(_datetime), do: ""

  defp scope_label(:workspace), do: gettext("Workspace")
  defp scope_label(:both), do: gettext("Include global")
  defp scope_label(:global), do: gettext("Global only")

  defp kind_label(:all), do: gettext("All")
  defp kind_label(:preference), do: gettext("Preference")
  defp kind_label(:rule), do: gettext("Rule")
  defp kind_label(:pattern), do: gettext("Pattern")
  defp kind_label(:fact), do: gettext("Fact")
  defp kind_label(:context), do: gettext("Context")

  defp kind_badge(kind), do: "#{kind} · #{kind_label(kind)}"

  defp maybe_put_kind(opts, :all), do: opts
  defp maybe_put_kind(opts, kind), do: Keyword.put(opts, :kind, kind)
end
