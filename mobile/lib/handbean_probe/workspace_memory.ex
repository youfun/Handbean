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
            provenance_by_id: %{},
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
            privacy_mode: :standard,
            editing: nil,
            confirming_delete: nil,
            now: nil,
            loading?: false,
            busy?: false,
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
        memory_scope: state.scope,
        privacy_mode: state.privacy_mode,
        lifecycle: state.lifecycle,
        query: state.query
      ]
      |> maybe_put_kind(state.kind)

    summary_opts = opts |> Keyword.delete(:workspace_id) |> Keyword.delete(:kind)

    items = MemoryStore.list_engrams(opts)

    provenance_opts = [
      workspace_id: workspace_id,
      memory_scope: state.scope,
      privacy_mode: state.privacy_mode
    ]

    provenance_by_id =
      case MemoryStore.provenance_many(Enum.map(items, & &1.id), provenance_opts) do
        {:ok, projections} -> projections
        {:error, _reason} -> %{}
      end

    {:ok,
     %{
       items: items,
       provenance_by_id: provenance_by_id,
       summary: MemoryStore.count_summary(workspace_id, summary_opts),
       now: DateTime.utc_now()
     }}
  end

  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = state), do: %{state | loading?: true, error: nil}

  @spec mutating(t()) :: t()
  def mutating(%__MODULE__{} = state), do: %{state | busy?: true, error: nil}

  @spec loaded(t(), {:ok, map()} | {:error, term()}) :: t()
  def loaded(%__MODULE__{} = state, {:ok, result}) do
    %{
      state
      | items: result.items,
        provenance_by_id: Map.get(result, :provenance_by_id, %{}),
        summary: result.summary,
        now: result.now,
        loading?: false,
        busy?: false,
        error: nil
    }
  end

  def loaded(%__MODULE__{} = state, {:error, reason}) do
    %{state | loading?: false, busy?: false, error: error_text(reason)}
  end

  def mutation_failed(%__MODULE__{} = state, reason),
    do: %{state | busy?: false, confirming_delete: nil, error: error_text(reason)}

  def mutation_succeeded(%__MODULE__{} = state),
    do: %{state | busy?: false, editing: nil, confirming_delete: nil, error: nil}

  def set_query(%__MODULE__{} = state, query) when is_binary(query), do: %{state | query: query}
  def set_query(%__MODULE__{} = state, _query), do: state

  def set_scope(%__MODULE__{privacy_mode: :local_only} = state, _scope),
    do: %{state | scope: :workspace}

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

  def load_privacy_mode(%__MODULE__{} = state, workspace_path) do
    settings = Handbean.Settings.effective_model_ai(workspace_path)
    privacy_mode = normalize_privacy_mode(settings.om_privacy_mode)
    scope = if privacy_mode == :local_only, do: :workspace, else: state.scope
    %{state | privacy_mode: privacy_mode, scope: scope}
  end

  def edit(%__MODULE__{} = state, id) when is_integer(id) do
    case Enum.find(state.items, &(&1.id == id)) do
      nil -> state
      item -> %{state | editing: %{id: id, content: item.content, kind: item.kind}, error: nil}
    end
  end

  def edit(%__MODULE__{} = state, _id), do: state

  def set_edit_content(%__MODULE__{editing: editing} = state, content)
      when is_map(editing) and is_binary(content),
      do: %{state | editing: %{editing | content: content}, error: nil}

  def set_edit_content(%__MODULE__{} = state, _content), do: state

  def set_edit_kind(%__MODULE__{editing: editing} = state, kind)
      when is_map(editing) and kind in @kinds,
      do: %{state | editing: %{editing | kind: kind}, error: nil}

  def set_edit_kind(%__MODULE__{} = state, _kind), do: state

  def cancel_edit(%__MODULE__{} = state), do: %{state | editing: nil, error: nil}

  def confirm_delete(%__MODULE__{} = state, id) when is_integer(id) do
    if Enum.any?(state.items, &(&1.id == id)),
      do: %{state | confirming_delete: id, error: nil},
      else: state
  end

  def confirm_delete(%__MODULE__{} = state, _id), do: state

  def dismiss_delete(%__MODULE__{} = state), do: %{state | confirming_delete: nil}

  def promote(workspace_id, %__MODULE__{} = state, id) when is_integer(id),
    do: MemoryStore.reinforce(id, access_opts(workspace_id, state))

  def save_edit(workspace_id, %__MODULE__{editing: editing} = state) when is_map(editing) do
    MemoryStore.update(
      editing.id,
      %{content: editing.content, kind: editing.kind},
      access_opts(workspace_id, state)
    )
  end

  def save_edit(_workspace_id, %__MODULE__{}), do: {:error, :not_editing}

  def delete(workspace_id, %__MODULE__{confirming_delete: id} = state) when is_integer(id),
    do: MemoryStore.delete(id, access_opts(workspace_id, state))

  def delete(_workspace_id, %__MODULE__{}), do: {:error, :not_confirming_delete}

  def locate(%__MODULE__{privacy_mode: :local_only} = state, id) when is_integer(id) do
    %{state | query: "##{id}", scope: :workspace, lifecycle: :all, kind: :all}
  end

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
    content =
      if state.editing do
        [workspace_card(workspace), edit_card(state), status_node(state)]
      else
        [
          workspace_card(workspace),
          builtin_memory_card(state),
          lifecycle_grid(state),
          filters(state),
          status_node(state)
          | memory_cards(state)
        ]
      end

    scroll(content ++ [delete_sheet(state)], id: "workspace-memory")
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
        Enum.map(available_scopes(state), fn scope ->
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

  defp status_node(%{busy?: true}),
    do: text(gettext("Saving memory…"), text_color: color(:muted), padding_bottom: 12)

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

  defp memory_cards(state),
    do: Enum.map(state.items, &memory_card(&1, state.now, state.provenance_by_id))

  defp memory_card(engram, now, provenance_by_id) do
    expired = expired?(engram, now)
    ink = if(expired, do: color(:hint), else: color(:ink))

    card(
      [
        row([
          text("##{engram.id}", font_weight: "bold", text_color: ink),
          gap(8),
          text(kind_badge(engram.kind), text_size: 12, text_color: ink),
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
        text(memory_projection(engram, provenance_by_id),
          text_size: 12,
          text_color: color(:muted),
          padding_top: 4
        ),
        text(engram.content, text_color: ink, padding_top: 12),
        association_nodes(engram),
        actions_row(
          [
            if(engram.short_term,
              do: primary_button(gettext("Promote"), {:memory_promote, engram.id})
            ),
            secondary_button(gettext("Edit"), {:memory_edit, engram.id}),
            danger_button(gettext("Delete"), {:memory_ask_delete, engram.id})
          ]
          |> Enum.reject(&is_nil/1)
        ),
        actions_row(
          [
            secondary_button(gettext("Copy #ID"), {:memory_copy, :id, engram.id}),
            secondary_button(gettext("Copy content"), {:memory_copy, :content, engram.id})
          ],
          padding_top: 4
        )
      ]
      |> List.flatten(),
      background: if(expired, do: color(:control), else: color(:card))
    )
  end

  defp edit_card(state) do
    editing = state.editing

    card([
      text(gettext("Edit memory #%{id}", id: editing.id),
        text_size: 17,
        font_weight: "bold",
        padding_bottom: 12
      ),
      field(gettext("Content"), editing.content, :memory_edit_content, multiline: true),
      text(gettext("Type"), text_size: 13, text_color: color(:muted), padding_bottom: 6),
      segment_row(Enum.map(Enum.take(@kinds, 3), &edit_kind_button(&1, editing))),
      segment_row(Enum.map(Enum.drop(@kinds, 3), &edit_kind_button(&1, editing)), padding_top: 8),
      actions_row([
        primary_button(gettext("Save"), :memory_save_edit),
        quiet_button(gettext("Cancel"), :memory_cancel_edit),
        danger_button(gettext("Delete"), {:memory_ask_delete, editing.id})
      ])
    ])
  end

  defp edit_kind_button(kind, editing) do
    segment_button(kind_label(kind), {:memory_edit_kind, kind}, editing.kind == kind)
  end

  defp delete_sheet(%{confirming_delete: nil}), do: nil

  defp delete_sheet(%{confirming_delete: id}) do
    sheet(
      [
        text(gettext("Delete memory #%{id}?", id: id), text_size: 16),
        text(gettext("This also removes its connections."),
          text_size: 13,
          text_color: color(:muted),
          padding_top: 8
        ),
        actions_row([
          danger_button(gettext("Delete"), :memory_delete),
          quiet_button(gettext("Keep"), :memory_dismiss_confirm)
        ])
      ],
      dismiss: :memory_dismiss_confirm,
      id: "memory-delete-confirm"
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

  def memory_scope(engram) do
    if SafeMap.get(engram.metadata || %{}, "scope") in [:global, "global"],
      do: :global,
      else: :workspace
  end

  def memory_source(engram) do
    case SafeMap.get(engram.metadata || %{}, "source") do
      source when source in [:agent, "agent", :mem_learn, "mem_learn"] ->
        gettext("Agent")

      source when source in [:reflection, "reflection", :reflector, "reflector"] ->
        gettext("Reflection")

      source when source in [:user, "user", :manual, "manual"] ->
        gettext("User")

      source when is_binary(source) and source != "" ->
        source

      source when is_atom(source) and not is_nil(source) ->
        Atom.to_string(source)

      _ ->
        gettext("Legacy")
    end
  end

  defp memory_projection(engram, provenance_by_id) do
    source = provenance_summary(Map.get(provenance_by_id, engram.id, []), engram)

    gettext("Scope: %{scope} · Source: %{source}",
      scope: projection_scope_label(memory_scope(engram)),
      source: source
    )
  end

  defp provenance_summary([], engram), do: memory_source(engram)

  defp provenance_summary(events, _engram) do
    event = List.last(events)
    source = List.first(event.sources)

    actor =
      case event.actor do
        :agent_tool -> gettext("Agent")
        :reflector -> gettext("Reflection")
        :user_ui -> gettext("User")
        :legacy -> gettext("Legacy")
        _ -> gettext("System")
      end

    status =
      case source && source.status do
        :available -> gettext("available; inspect in Web")
        :changed -> gettext("changed; inspect in Web")
        :deleted -> gettext("deleted")
        :inaccessible -> gettext("unavailable")
        :unresolved_legacy -> gettext("legacy source unresolved")
        _ -> gettext("no exact source")
      end

    "#{actor} · #{status}"
  end

  defp format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  defp format_date(_datetime), do: ""

  defp scope_label(:workspace), do: gettext("Workspace")
  defp scope_label(:both), do: gettext("Include global")
  defp scope_label(:global), do: gettext("Global only")

  defp projection_scope_label(:workspace), do: gettext("Workspace")
  defp projection_scope_label(:global), do: gettext("Global")

  defp kind_label(:all), do: gettext("All")
  defp kind_label(:preference), do: gettext("Preference")
  defp kind_label(:rule), do: gettext("Rule")
  defp kind_label(:pattern), do: gettext("Pattern")
  defp kind_label(:fact), do: gettext("Fact")
  defp kind_label(:context), do: gettext("Context")

  defp kind_badge(kind), do: "#{kind} · #{kind_label(kind)}"

  defp maybe_put_kind(opts, :all), do: opts
  defp maybe_put_kind(opts, kind), do: Keyword.put(opts, :kind, kind)

  defp access_opts(workspace_id, state) do
    [
      workspace_id: workspace_id,
      memory_scope: state.scope,
      privacy_mode: state.privacy_mode,
      provenance: %{actor: :user_ui}
    ]
  end

  defp available_scopes(%{privacy_mode: :local_only}), do: [:workspace]
  defp available_scopes(_state), do: @scopes

  defp normalize_privacy_mode(mode) when mode in [:local_only, "local_only"], do: :local_only
  defp normalize_privacy_mode(_mode), do: :standard

  defp error_text(%Ecto.Changeset{}), do: gettext("Memory content and type are required")
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
