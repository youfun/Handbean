defmodule HandbeanProbe.ModelSettings.Render do
  @moduledoc """
  Mob node tree for the native model settings overview.

  Renders from the `HandbeanProbe.ModelSettings` state only; no disk reads. Editor
  forms live in `HandbeanProbe.ModelSettings.RenderForms`, the delete sheet in
  `HandbeanProbe.ModelSettings.RenderConfirm`.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI
  alias Handbean.Agent.Reasoning
  alias HandbeanProbe.ModelSettings.{Labels, Providers, RenderForms, SubscriptionRender}

  def render(state) do
    Process.put({__MODULE__, :select_open}, state.select_open)

    [
      scope_bar(state),
      notice(state.notice),
      help_block(
        state,
        :provider_connection,
        gettext("Each provider has its own URL, protocol, and API key."),
        gettext("Models use that provider's connection settings. Edit them on the provider form.")
      )
    ] ++ if(state.form, do: RenderForms.form(state), else: overview(state))
  end

  @doc "Web Model / AI panel: scope, default model, reasoning, advisor, memory."
  def model_ai(state) do
    Process.put({__MODULE__, :select_open}, state.select_open)

    [scope_bar(state), notice(state.notice)] ++
      defaults_card(state) ++ advisor_card(state) ++ subagent_card(state) ++ memory_card(state)
  end

  @doc "Web Workspace Models panel: allowlist and policy default."
  def workspace_models(state) do
    Process.put({__MODULE__, :select_open}, state.select_open)
    policy_card(state)
  end

  @doc "Web Available Models panel: catalog, providers, subscription sign-in."
  def available_models(state) do
    Process.put({__MODULE__, :select_open}, state.select_open)

    [
      notice(state.notice),
      help_block(
        state,
        :provider_connection,
        gettext("Each provider has its own URL, protocol, and API key."),
        gettext("Models use that provider's connection settings. Edit them on the provider form.")
      )
    ] ++
      if(state.form,
        do: RenderForms.form(state),
        else: SubscriptionRender.section(state) ++ catalog_header(state) ++ catalog_rows(state)
      )
  end

  @doc "A select with the shared menu affordance."
  def settings_select(value, options, id, props \\ []) do
    open? = Process.get({__MODULE__, :select_open}) == id

    select(
      value,
      options,
      Keyword.merge(
        [
          id: id,
          icon_content_description: gettext("Open menu"),
          open: open?,
          on_toggle: {:toggle_select, id}
        ],
        props
      )
    )
  end

  @doc "Summary line plus a collapsible detail paragraph."
  def help_block(state, key, summary, detail) do
    open? = Map.get(state.help_open || %{}, key, false)

    node(:column, [fill_width: true], [
      settings_caption(summary),
      if(open?, do: settings_caption(detail)),
      settings_group([
        settings_nav_row(
          if(open?, do: gettext("Hide details"), else: gettext("More details")),
          "",
          {:toggle_help, key}
        )
      ])
    ])
  end

  defp overview(state) do
    defaults_card(state) ++
      advisor_card(state) ++
      subagent_card(state) ++
      memory_card(state) ++
      policy_card(state) ++
      SubscriptionRender.section(state) ++
      catalog_header(state) ++
      catalog_rows(state)
  end

  defp scope_bar(state) do
    settings_group([
      settings_form_field(
        gettext("Scope"),
        settings_select(
          scope_label(state.scope),
          [
            select_option(gettext("Global default"), {:scope, :global}, state.scope == :global),
            select_option(
              gettext("Current workspace"),
              {:scope, :workspace},
              state.scope == :workspace
            )
          ],
          "select-scope"
        )
      )
    ])
  end

  defp scope_label(:global), do: gettext("Global default")
  defp scope_label(_), do: gettext("Current workspace")

  defp defaults_card(state) do
    d = state.defaults
    src = state.sources

    [
      settings_section(gettext("Model")),
      settings_group([
        settings_form_field(
          gettext("Default model"),
          settings_select(
            Labels.default_model(d.default_model, state),
            default_model_options(state),
            "select-default"
          )
        ),
        inherit_row(
          state.scope == :workspace && src[:default_model] == :workspace,
          gettext("Use global default model"),
          {:inherit, :default_model}
        ),
        settings_form_field(
          gettext("Reasoning"),
          settings_select(
            Labels.reasoning(d.reasoning),
            Enum.map(
              Reasoning.levels(),
              &select_option(Labels.reasoning(&1), {:reasoning, &1}, d.reasoning == &1)
            ),
            "select-reasoning"
          )
        ),
        inherit_row(
          state.scope == :workspace && src[:reasoning] == :workspace,
          gettext("Use global reasoning"),
          {:inherit, :reasoning}
        ),
        inherit_row(
          state.scope == :workspace,
          gettext("Clear all workspace Model/AI overrides"),
          :inherit_all
        )
      ])
    ]
  end

  defp advisor_card(state) do
    d = state.defaults

    unset =
      if state.scope == :global,
        do: gettext("Not configured"),
        else: gettext("No workspace model")

    fields = [
      settings_form_field(
        gettext("Advisor model"),
        settings_select(
          Labels.follow_label(d.advisor_model, state, unset),
          follow_options(state, :advisor_model, unset),
          "select-advisor"
        )
      ),
      settings_form_field(
        gettext("Think level"),
        settings_select(
          Labels.think_level(d.advisor_reasoning),
          think_options(:advisor_reasoning, d.advisor_reasoning),
          "select-advisor-reasoning"
        )
      )
    ]

    fields =
      if state.scope == :workspace do
        fields ++
          [
            settings_form_field(
              gettext("Workspace advisor"),
              settings_select(
                Labels.advisor_mode(d.advisor_mode),
                [
                  select_option(
                    Labels.advisor_mode(:inherit),
                    {:advisor_mode, :inherit},
                    d.advisor_mode == :inherit
                  ),
                  select_option(
                    Labels.advisor_mode(:custom),
                    {:advisor_mode, :custom},
                    d.advisor_mode == :custom
                  ),
                  select_option(
                    Labels.advisor_mode(:disabled),
                    {:advisor_mode, :disabled},
                    d.advisor_mode == :disabled
                  )
                ],
                "select-advisor-mode"
              )
            )
          ]
      else
        fields
      end

    [settings_section(gettext("Advisor")), settings_group(fields)]
  end

  defp subagent_card(state) do
    d = state.defaults
    follow = gettext("Follow current conversation")

    fields = [
      settings_form_field(
        gettext("Subagent model"),
        settings_select(
          Labels.follow_label(d.subagent_model, state, follow),
          follow_options(state, :subagent_model, follow),
          "select-subagent"
        )
      ),
      settings_form_field(
        gettext("Think level"),
        settings_select(
          Labels.think_level(d.subagent_reasoning),
          think_options(:subagent_reasoning, d.subagent_reasoning),
          "select-subagent-reasoning"
        )
      )
    ]

    fields =
      if state.scope == :workspace do
        fields ++
          [
            settings_form_field(
              gettext("Workspace subagent"),
              settings_select(
                Labels.subagent_mode(d.subagent_mode),
                [
                  select_option(
                    Labels.subagent_mode(:inherit),
                    {:subagent_mode, :inherit},
                    d.subagent_mode == :inherit
                  ),
                  select_option(
                    Labels.subagent_mode(:custom),
                    {:subagent_mode, :custom},
                    d.subagent_mode == :custom
                  ),
                  select_option(
                    Labels.subagent_mode(:parent),
                    {:subagent_mode, :parent},
                    d.subagent_mode == :parent
                  )
                ],
                "select-subagent-mode"
              )
            )
          ]
      else
        fields
      end

    [settings_section(gettext("Subagent")), settings_group(fields)]
  end

  defp memory_card(state) do
    d = state.defaults
    follow = gettext("Follow default model")

    rows = [
      settings_toggle_row(
        gettext("Enable memory reflection"),
        d.om_reflector_enabled,
        {:model_field, :om_reflector_enabled},
        id: "toggle-memory-reflection"
      ),
      settings_form_field(
        gettext("Memory model"),
        settings_select(
          Labels.follow_label(d.om_model, state, follow),
          follow_options(state, :om_model, follow),
          "select-memory"
        )
      ),
      settings_form_field(
        gettext("Think level"),
        settings_select(
          Labels.think_level(d.om_reasoning),
          think_options(:om_reasoning, d.om_reasoning),
          "select-memory-reasoning"
        )
      ),
      settings_form_field(
        gettext("Memory scope"),
        settings_select(
          Labels.memory_scope(d.om_memory_scope),
          Enum.map(
            ~w(workspace global both),
            &select_option(
              Labels.memory_scope(&1),
              {:om_memory_scope, &1},
              d.om_memory_scope == &1
            )
          ),
          "select-memory-scope"
        )
      ),
      settings_form_field(
        gettext("Privacy mode"),
        settings_select(
          Labels.privacy(d.om_privacy_mode),
          [
            select_option(
              Labels.privacy("standard"),
              {:om_privacy_mode, "standard"},
              d.om_privacy_mode == "standard"
            ),
            select_option(
              Labels.privacy("local_only"),
              {:om_privacy_mode, "local_only"},
              d.om_privacy_mode == "local_only"
            )
          ],
          "select-privacy"
        )
      )
    ]

    workspace_rows =
      Enum.map(Map.get(state, :memory_workspaces, []), fn ws ->
        settings_toggle_row(
          ws.name,
          ws.enabled,
          {:workspace_builtin_memory, ws.id},
          id: "toggle-workspace-memory-#{ws.id}"
        )
      end)

    save = [
      settings_nav_row(gettext("Save memory reflection settings"), "", :save_memory_details)
    ]

    [
      settings_section(gettext("Memory Reflection")),
      settings_group(rows ++ workspace_rows ++ save)
    ]
  end

  defp policy_card(state) do
    policy = state.policy
    query = Map.get(state, :policy_query, "") || ""

    access = [
      if(match?(%{mode: :invalid}, policy),
        do:
          text(Labels.policy_help(policy),
            text_size: 12,
            text_color: color(:danger),
            padding: 16
          )
      ),
      settings_form_field(
        gettext("Access mode"),
        settings_select(
          access_mode_label(policy.mode),
          [
            select_option(
              gettext("Unrestricted"),
              {:policy_mode, :unrestricted},
              policy.mode == :unrestricted
            ),
            select_option(
              gettext("Only checked models"),
              {:policy_mode, :restricted},
              policy.mode == :restricted
            )
          ],
          "select-policy-mode"
        )
      )
    ]

    allow = if policy.mode == :restricted, do: policy_allow_rows(state, query), else: []

    default_and_save = [
      settings_form_field(
        gettext("Workspace default model"),
        settings_select(
          policy.default_model || gettext("None (use provider default)"),
          policy_default_options(state),
          "select-policy-default"
        )
      ),
      settings_nav_row(gettext("Save"), "", :save_policy)
    ]

    [
      settings_section(gettext("Workspace models")),
      settings_group(access ++ allow ++ default_and_save)
    ]
  end

  defp policy_allow_rows(state, query) do
    q = query |> to_string() |> String.trim() |> String.downcase()

    grouped =
      state.models
      |> Enum.filter(&policy_model_match?(&1, q))
      |> Enum.group_by(& &1.provider_id)

    search = [
      field(gettext("Search models or providers"), query, {:model_field, :policy_query})
    ]

    blocks =
      if grouped == %{} do
        [
          text(gettext("No matching models"),
            text_size: 13,
            text_color: color(:muted),
            padding: 16
          )
        ]
      else
        Enum.flat_map(grouped, fn {provider_id, models} ->
          selected = policy_provider_selected_count(state, provider_id)
          total = Enum.count(state.models, &(&1.provider_id == provider_id))

          header = [
            settings_value_row(
              provider_label(state, provider_id),
              gettext("%{selected} / %{total}", selected: selected, total: total)
            ),
            settings_nav_row(gettext("Select all"), "", {:policy_provider, provider_id, :all}),
            settings_nav_row(gettext("Clear"), "", {:policy_provider, provider_id, :none})
          ]

          header ++
            Enum.map(models, fn model ->
              checked? =
                state.policy.allowed
                |> Map.get(model.provider_id, MapSet.new())
                |> MapSet.member?(model.model_id)

              settings_check_row(
                model.name || model.model_id,
                checked?,
                {:toggle_policy_model, model.provider_id, model.model_id}
              )
            end)
        end)
      end

    search ++ blocks
  end

  defp policy_model_match?(_model, ""), do: true

  defp policy_model_match?(model, query) do
    [model.name, model.model_id, model.provider_id, model.id]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), query))
  end

  defp policy_provider_selected_count(state, provider_id) do
    allowed = Map.get(state.policy.allowed, provider_id, MapSet.new())

    Enum.count(state.models, fn model ->
      model.provider_id == provider_id and MapSet.member?(allowed, model.model_id)
    end)
  end

  defp provider_label(state, provider_id) do
    case Enum.find(state.providers, &(&1.id == provider_id)) do
      nil -> provider_id
      provider -> provider.name
    end
  end

  defp access_mode_label(:restricted), do: gettext("Only checked models")
  defp access_mode_label(:invalid), do: gettext("Invalid")
  defp access_mode_label(_), do: gettext("Unrestricted")

  defp inherit_row(true, label, tag), do: settings_nav_row(label, "", tag, quiet: true)

  defp inherit_row(_, _label, _tag), do: nil

  defp think_options(field, current) do
    [select_option(gettext("Model default"), {field, ""}, current in [nil, ""])] ++
      Enum.map(
        Reasoning.levels(),
        &select_option(Labels.reasoning(&1), {field, &1}, current == &1)
      )
  end

  defp catalog_header(state) do
    [
      settings_group([
        settings_nav_row(gettext("Add provider"), "", :add_provider),
        settings_nav_row(gettext("Add model"), "", :add_model)
      ])
    ] ++ provider_picker(state)
  end

  defp provider_picker(%{providers: []}) do
    [settings_caption(gettext("No providers yet. Add a provider, then add a model."))]
  end

  defp provider_picker(state) do
    selected = Providers.selected_entry(state)
    label = if selected, do: selected.name, else: gettext("Choose a provider")

    [
      settings_group([
        settings_form_field(
          gettext("Provider"),
          settings_select(
            label,
            Enum.map(
              state.providers,
              &select_option(&1.name, {:select_provider, &1.id}, state.selected_provider == &1.id)
            ),
            "select-provider"
          )
        )
      ])
    ]
  end

  defp catalog_rows(%{providers: []}), do: []

  defp catalog_rows(state) do
    case Providers.selected_entry(state) do
      nil ->
        [settings_caption(gettext("Select a provider to see its models."))]

      provider ->
        models = Enum.filter(state.models, &(&1.provider_id == provider.id))
        provider_groups(provider, models)
    end
  end

  defp provider_groups(provider, models) do
    count =
      if models == [],
        do: gettext("None"),
        else: Integer.to_string(length(models))

    default_props = if provider.is_default, do: [disabled: true], else: []

    info = [
      settings_value_row(gettext("API Key"), Labels.key_value(provider.key_status)),
      settings_value_row(gettext("Models"), count)
    ]

    actions = [
      if(provider.fetchable,
        do: settings_nav_row(gettext("Fetch models"), "", {:fetch_models, provider.id})
      ),
      settings_nav_row(gettext("Edit provider"), "", {:edit_provider, provider.id}),
      settings_check_row(
        gettext("Default provider"),
        provider.is_default,
        {:set_default_provider, provider.id},
        default_props
      ),
      if(Enum.any?(models, &Map.get(&1, :enabled, true)),
        do: settings_nav_row(gettext("Disable all"), "", {:disable_provider_models, provider.id})
      ),
      settings_nav_row(gettext("Delete provider"), "", {:ask_delete_provider, provider.id},
        danger: true
      )
    ]

    [settings_group(info), settings_group(actions)] ++ provider_model_group(models)
  end

  defp provider_model_group([]) do
    [settings_caption(gettext("No models yet for this provider."))]
  end

  defp provider_model_group(models) do
    [
      settings_section(gettext("Models")),
      settings_group(Enum.map(models, &catalog_model_row/1))
    ]
  end

  defp catalog_model_row(model) do
    enabled? = Map.get(model, :enabled, true)
    edit = {:edit_model, model.provider_id, model.model_id}
    name = model.name || model.model_id

    row(
      [
        text(name, text_size: 16, max_lines: 1),
        node(:box, weight: 1),
        node(:toggle,
          id: "toggle-model-#{model.provider_id}-#{model.model_id}",
          value: enabled?,
          color: color(:ink),
          on_change:
            {self(), {:toggle_model_enabled, model.provider_id, model.model_id, not enabled?}}
        )
      ],
      fill_width: true,
      padding_top: 10,
      padding_bottom: 10,
      padding_left: 16,
      padding_right: 16,
      on_tap: {self(), edit},
      id: "model-row-#{model.provider_id}-#{model.model_id}"
    )
  end

  defp default_model_options(state) do
    models = if state.scope == :workspace, do: state.allowed_models, else: state.models

    unset = [
      select_option(
        gettext("None (use provider default)"),
        {:default_model, ""},
        state.defaults.default_model == nil
      )
    ]

    unset ++
      Enum.map(
        models,
        &select_option(&1.name, {:default_model, &1.id}, state.defaults.default_model == &1.id)
      )
  end

  defp follow_options(state, field, follow_label) do
    current = Map.get(state.defaults, field)

    [select_option(follow_label, {field, ""}, current in [nil, ""])] ++
      Enum.map(state.models, &select_option(&1.name, {field, &1.id}, current == &1.id))
  end

  defp policy_default_options(state) do
    allowed =
      Enum.filter(state.models, fn model ->
        state.policy.mode != :restricted or
          state.policy.allowed
          |> Map.get(model.provider_id, MapSet.new())
          |> MapSet.member?(model.model_id)
      end)

    [select_option(gettext("None"), {:policy_default, ""}, state.policy.default_model == nil)] ++
      Enum.map(
        allowed,
        &select_option(&1.id, {:policy_default, &1.id}, state.policy.default_model == &1.id)
      )
  end
end
