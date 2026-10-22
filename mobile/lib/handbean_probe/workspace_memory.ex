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
            select_open: nil,
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
    do: %{state | scope: :workspace, select_open: nil}

  def set_scope(%__MODULE__{} = state, scope) when scope in @scopes,
    do: %{state | scope: scope, select_open: nil}

  def set_scope(%__MODULE__{} = state, _scope), do: state

  def set_lifecycle(%__MODULE__{} = state, lifecycle) when lifecycle in @lifecycles,
    do: %{state | lifecycle: lifecycle, select_open: nil}

  def set_lifecycle(%__MODULE__{} = state, _lifecycle), do: state

  def set_kind(%__MODULE__{} = state, kind) when kind in [:all | @kinds],
    do: %{state | kind: kind, select_open: nil}

  def set_kind(%__MODULE__{} = state, _kind), do: state

  def toggle_select(%__MODULE__{select_open: id} = state, id) when is_binary(id),
    do: %{state | select_open: nil}

  def toggle_select(%__MODULE__{} = state, id) when is_binary(id),
    do: %{state | select_open: id}

  def toggle_select(%__MODULE__{} = state, _id), do: state

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
  def render(%__MODULE__{} = state, _workspace) do
    content =
      if state.editing do
        [edit_form(state), status_node(state)]
      else
        [
          builtin_group(state),
          filter_group(state),
          status_node(state),
          settings_section(gettext("Memories")),
          memories_group(state)
        ]
      end

    scroll(content ++ [delete_sheet(state)], id: "workspace-memory")
  end

  defp builtin_group(state) do
    node(:column, [fill_width: true], [
      settings_group([
        settings_toggle_row(
          gettext("Use built-in memory"),
          state.builtin_memory_enabled,
          :memory_builtin
        )
      ]),
      settings_caption(
        gettext("External memory tools remain available when built-in memory is off.")
      )
    ])
  end

  defp filter_group(state) do
    node(:column, [fill_width: true], [
      settings_section(gettext("Filter")),
      settings_group([
        settings_form_field(
          gettext("Search"),
          node(:text_field,
            id: "memory_query",
            value: state.query,
            placeholder: gettext("Search content or #ID…"),
            plain: true,
            background: color(:card),
            fill_width: true,
            on_change: {self(), :memory_query}
          )
        ),
        row(
          [
            compact_filter(gettext("Status"), lifecycle_select(state)),
            gap(8),
            compact_filter(gettext("Scope"), scope_select(state)),
            gap(8),
            compact_filter(gettext("Type"), kind_select(state))
          ],
          id: "memory-filter-row",
          fill_width: true,
          align: "top",
          padding_left: 12,
          padding_right: 12,
          padding_top: 8,
          padding_bottom: 12
        )
      ])
    ])
  end

  defp compact_filter(label, control) do
    node(:column, [weight: 1, fill_width: true], [
      text(label, text_size: 12, text_color: color(:muted), max_lines: 1, padding_bottom: 4),
      control
    ])
  end

  defp lifecycle_select(state) do
    choices = lifecycle_choices(state.summary)

    filter_select(
      choice_label(choices, state.lifecycle) || gettext("All"),
      Enum.map(choices, fn {id, label, count} ->
        select_option(counted(label, count), {:memory_lifecycle, id}, state.lifecycle == id)
      end),
      "select-memory-filter-lifecycle",
      state
    )
  end

  defp scope_select(state) do
    scopes = available_scopes(state)

    filter_select(
      scope_label(state.scope),
      Enum.map(scopes, fn scope ->
        select_option(scope_label(scope), {:memory_scope, scope}, state.scope == scope)
      end),
      "select-memory-filter-scope",
      state
    )
  end

  defp kind_select(state) do
    kinds = [:all | @kinds]

    filter_select(
      kind_label(state.kind),
      Enum.map(kinds, fn kind ->
        select_option(
          counted(kind_label(kind), kind_count(state.summary, kind)),
          {:memory_kind, kind},
          state.kind == kind
        )
      end),
      "select-memory-filter-kind",
      state
    )
  end

  defp filter_select(value, options, id, state) do
    select(
      value,
      options,
      id: id,
      icon_content_description: gettext("Open menu"),
      open: state.select_open == id,
      on_toggle: {:toggle_select, id}
    )
  end

  defp lifecycle_choices(summary) do
    [
      {:active, gettext("Active memory"), summary.active},
      {:long_term, gettext("Long-term memory"), summary.long_term},
      {:short_term, gettext("Short-term memory"), summary.short_term},
      {:expired, gettext("Expired"), summary.expired}
    ]
  end

  defp choice_label(choices, id) do
    case Enum.find(choices, fn {choice_id, _, _} -> choice_id == id end) do
      {_, label, _count} -> label
      nil -> nil
    end
  end

  defp counted(label, count), do: "#{label}  #{count}"

  defp kind_count(summary, :all), do: Enum.sum(Map.values(summary.by_kind))
  defp kind_count(summary, kind), do: Map.get(summary.by_kind, kind, 0)

  defp status_node(%{loading?: true}),
    do: text(gettext("Loading memory…"), text_color: color(:muted), padding_bottom: 12)

  defp status_node(%{busy?: true}),
    do: text(gettext("Saving memory…"), text_color: color(:muted), padding_bottom: 12)

  defp status_node(%{error: error}) when is_binary(error),
    do: text(error, text_color: color(:danger), padding_bottom: 12)

  defp status_node(_state), do: nil

  defp memories_group(%{items: [], loading?: false, error: nil}) do
    settings_group([
      text(gettext("No memories match these filters"),
        text_size: 15,
        padding_left: 16,
        padding_right: 16,
        padding_top: 14,
        padding_bottom: 6
      ),
      text(gettext("Try another scope, lifecycle, type, or search."),
        text_size: 13,
        text_color: color(:muted),
        padding_left: 16,
        padding_right: 16,
        padding_bottom: 14
      )
    ])
  end

  defp memories_group(state) do
    node(
      :column,
      [fill_width: true],
      Enum.map(state.items, &memory_group(&1, state.now, state.provenance_by_id))
    )
  end

  defp memory_group(engram, now, provenance_by_id) do
    rows = [
      settings_nav_row(
        preview(engram.content),
        kind_label(engram.kind),
        {:memory_edit, engram.id}
      ),
      settings_value_row("##{engram.id}", lifecycle_text(engram, now)),
      settings_value_row(
        projection_scope_label(memory_scope(engram)),
        provenance_summary(Map.get(provenance_by_id, engram.id, []), engram)
      )
      | association_rows(engram)
    ]

    rows =
      if engram.short_term do
        rows ++ [settings_nav_row(gettext("Promote"), "", {:memory_promote, engram.id})]
      else
        rows
      end

    settings_group(rows)
  end

  defp preview(content) when is_binary(content) do
    compact = content |> String.trim() |> String.replace(~r/\s+/u, " ")

    if String.length(compact) > 36 do
      String.slice(compact, 0, 36) <> "…"
    else
      compact
    end
  end

  defp preview(_content), do: gettext("Memory")

  defp edit_form(state) do
    editing = state.editing
    item = Enum.find(state.items, &(&1.id == editing.id))

    settings_group(
      [
        settings_form_field(
          gettext("Content"),
          node(:text_field,
            id: "memory_edit_content",
            value: editing.content,
            multiline: true,
            plain: true,
            fill_width: true,
            on_change: {self(), :memory_edit_content}
          )
        )
      ] ++
        Enum.map(@kinds, fn kind ->
          settings_check_row(kind_label(kind), editing.kind == kind, {:memory_edit_kind, kind})
        end) ++
        edit_actions(item, editing)
    )
  end

  defp edit_actions(item, editing) do
    [
      if(item && item.short_term,
        do: settings_nav_row(gettext("Promote"), "", {:memory_promote, editing.id})
      ),
      settings_nav_row(gettext("Copy #ID"), "", {:memory_copy, :id, editing.id}),
      settings_nav_row(gettext("Copy content"), "", {:memory_copy, :content, editing.id}),
      settings_nav_row(gettext("Save"), "", :memory_save_edit),
      settings_nav_row(gettext("Cancel"), "", :memory_cancel_edit, quiet: true),
      settings_nav_row(gettext("Delete"), "", {:memory_ask_delete, editing.id})
    ]
    |> Enum.reject(&is_nil/1)
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

  defp association_rows(engram) do
    Enum.map(associations(engram), fn association ->
      settings_nav_row(
        "#{association.direction} #{association.kind} ##{association.id}",
        "",
        {:memory_related, association.id}
      )
    end)
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
        :available -> gettext("available")
        :changed -> gettext("changed")
        :deleted -> gettext("deleted")
        :inaccessible -> gettext("unavailable")
        :unresolved_legacy -> gettext("legacy source unresolved")
        _ -> gettext("no exact source")
      end

    "#{actor} · #{status}"
  end

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
