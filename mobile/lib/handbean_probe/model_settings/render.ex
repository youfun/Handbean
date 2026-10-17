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

  @doc "A select with the shared menu affordance."
  def settings_select(value, options, id) do
    open? = Process.get({__MODULE__, :select_open}) == id

    select(value, options,
      id: id,
      icon_content_description: gettext("Open menu"),
      open: open?,
      on_toggle: {:toggle_select, id}
    )
  end

  @doc "Summary line plus a collapsible detail paragraph."
  def help_block(state, key, summary, detail) do
    open? = Map.get(state.help_open || %{}, key, false)

    node(:column, [fill_width: true, padding_bottom: 8], [
      text(summary, text_size: 12, text_color: color(:muted)),
      quiet_button(
        if(open?, do: gettext("Hide details"), else: gettext("More details")),
        {:toggle_help, key},
        text_size: 12
      ),
      if(open?, do: text(detail, text_size: 12, text_color: color(:hint), padding_top: 4))
    ])
  end

  defp overview(state) do
    defaults_card(state) ++
      memory_card(state) ++
      policy_card(state) ++
      SubscriptionRender.section(state) ++
      catalog_header(state) ++
      catalog_rows(state)
  end

  defp scope_bar(state) do
    segment_row(
      [
        segment_button(gettext("Global default"), {:scope, :global}, state.scope == :global),
        segment_button(
          gettext("Current workspace"),
          {:scope, :workspace},
          state.scope == :workspace
        )
      ],
      padding_top: 4,
      padding_bottom: 8
    )
  end

  defp defaults_card(state) do
    d = state.defaults
    src = state.sources

    [
      card(
        [
          text(gettext("Default model"), text_size: 16),
          text(Labels.source_line(:default_model, src, d.default_model),
            text_size: 12,
            text_color: color(:hint),
            padding_top: 4,
            padding_bottom: 8
          ),
          if(state.scope == :workspace,
            do:
              help_block(
                state,
                :default_priority,
                gettext("This workspace can override the global default."),
                gettext(
                  "Chat uses the Model/AI default first. If that is unset, it uses the workspace policy default, then the catalog provider default."
                )
              )
          ),
          settings_select(
            Labels.default_model(d.default_model, state),
            default_model_options(state),
            "select-default"
          ),
          if(state.scope == :workspace && src[:default_model] == :workspace,
            do: quiet_button(gettext("Use global default model"), {:inherit, :default_model})
          ),
          text(gettext("Reasoning"), text_size: 14, padding_top: 16),
          text(Labels.source_line(:reasoning, src, d.reasoning),
            text_size: 12,
            text_color: color(:hint),
            padding_top: 4,
            padding_bottom: 8
          )
        ] ++
          spaced([
            settings_select(
              Labels.reasoning(d.reasoning),
              Enum.map(
                Reasoning.levels(),
                &select_option(Labels.reasoning(&1), {:reasoning, &1}, d.reasoning == &1)
              ),
              "select-reasoning"
            ),
            if(state.scope == :workspace && src[:reasoning] == :workspace,
              do: quiet_button(gettext("Use global reasoning"), {:inherit, :reasoning})
            ),
            if(state.scope == :workspace,
              do: quiet_button(gettext("Clear all workspace Model/AI overrides"), :inherit_all)
            )
          ])
      )
    ]
  end

  defp memory_card(state) do
    [
      card(
        [
          text(gettext("Observational memory"), text_size: 16),
          text(
            gettext("Built-in memory is enabled per workspace in Workspace Memory settings."),
            text_size: 12,
            text_color: color(:hint),
            padding_top: 4,
            padding_bottom: 8
          )
        ] ++ memory_details(state)
      )
    ]
  end

  defp memory_details(state) do
    d = state.defaults

    [
      text(gettext("Memory model"), text_size: 13, padding_top: 12),
      settings_select(
        Labels.follow(d.om_model, gettext("Follow default model")),
        follow_options(state, :om_model, gettext("Follow default model")),
        "select-memory"
      ),
      text(gettext("Memory scope"), text_size: 13, padding_top: 12),
      settings_select(
        Labels.memory_scope(d.om_memory_scope),
        Enum.map(
          ~w(workspace global both),
          &select_option(Labels.memory_scope(&1), {:om_memory_scope, &1}, d.om_memory_scope == &1)
        ),
        "select-memory-scope"
      ),
      text(gettext("Privacy mode"), text_size: 13, padding_top: 12),
      help_block(
        state,
        :privacy,
        gettext("Standard may use the same remote models as chat."),
        gettext(
          "Data isolated keeps observer and reflector on the device-local path. It does not mean the app never uses the network."
        )
      ),
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
      ),
      field(
        gettext("Recent context limit"),
        to_string(d.om_max_recent_context),
        {:model_field, :om_max_recent_context},
        keyboard: "number"
      ),
      secondary_button(gettext("Save memory details"), :save_memory_details, fill_width: true)
    ]
  end

  defp policy_card(state) do
    policy = state.policy

    [
      card(
        [
          text(gettext("Workspace model policy"), text_size: 16),
          text(Labels.policy_help(policy),
            text_size: 12,
            text_color: color(:hint),
            padding_top: 4,
            padding_bottom: 8
          ),
          help_block(
            state,
            :policy_default,
            gettext("A policy default is only used when Model/AI has no model."),
            gettext(
              "If both a Model/AI default and a policy default are set, chat uses the Model/AI default."
            )
          ),
          segment_row(
            [
              segment_button(
                gettext("Unrestricted"),
                {:policy_mode, :unrestricted},
                policy.mode == :unrestricted
              ),
              segment_button(
                gettext("Allowlist"),
                {:policy_mode, :restricted},
                policy.mode == :restricted
              )
            ],
            padding_bottom: 8
          )
        ] ++
          if(policy.mode == :restricted, do: policy_allow_rows(state), else: []) ++
          [
            text(gettext("Policy default"), text_size: 13, padding_top: 12),
            settings_select(
              policy.default_model || gettext("None"),
              policy_default_options(state),
              "select-policy-default"
            ),
            secondary_button(gettext("Save workspace policy"), :save_policy,
              fill_width: true,
              padding_top: 8
            )
          ]
      )
    ]
  end

  defp policy_allow_rows(state) do
    Enum.map(state.models, fn model ->
      checked? =
        state.policy.allowed
        |> Map.get(model.provider_id, MapSet.new())
        |> MapSet.member?(model.model_id)

      option_button(
        model.id,
        {:toggle_policy_model, model.provider_id, model.model_id},
        checked?
      )
    end)
  end

  defp catalog_header(state) do
    [
      row(
        [
          text(gettext("Available Models"), text_size: 16, weight: 1)
          | spaced([
              secondary_button(gettext("Add provider"), :add_provider),
              secondary_button(gettext("Add model"), :add_model)
            ])
        ],
        align: "center",
        padding_top: 8,
        padding_bottom: 8
      )
    ] ++ provider_picker(state)
  end

  defp provider_picker(%{providers: []}) do
    [
      card([
        text(gettext("No providers yet. Add a provider, then add a model."),
          text_size: 13,
          text_color: color(:hint)
        )
      ])
    ]
  end

  defp provider_picker(state) do
    selected = Providers.selected_entry(state)
    label = if selected, do: selected.name, else: gettext("Choose a provider")

    [
      text(gettext("Provider"), text_size: 13, padding_top: 4, padding_bottom: 4),
      settings_select(
        label,
        Enum.map(
          state.providers,
          &select_option(&1.name, {:select_provider, &1.id}, state.selected_provider == &1.id)
        ),
        "select-provider"
      )
    ]
  end

  defp catalog_rows(%{providers: []}), do: []

  defp catalog_rows(state) do
    case Providers.selected_entry(state) do
      nil ->
        [
          text(gettext("Select a provider to see its models."),
            text_size: 12,
            text_color: color(:hint)
          )
        ]

      provider ->
        models = Enum.filter(state.models, &(&1.provider_id == provider.id))
        [provider_row(provider, models)]
    end
  end

  defp provider_row(provider, models) do
    count_line =
      if models == [],
        do: gettext("This provider has no models yet."),
        else: gettext("%{count} models", count: length(models))

    card(
      [
        row(
          [
            text(provider.name, text_size: 15, weight: 1)
            | provider_actions(provider)
          ],
          align: "center"
        ),
        text(Labels.key_status(provider.key_status),
          text_size: 12,
          text_color: color(:hint),
          padding_top: 6
        ),
        text(count_line, text_size: 12, text_color: color(:hint), padding_bottom: 8),
        quiet_button(gettext("Delete provider"), {:ask_delete_provider, provider.id},
          text_color: color(:danger)
        )
      ] ++ provider_models(models)
    )
  end

  defp provider_models([]) do
    [
      text(gettext("No models yet for this provider."),
        text_size: 12,
        text_color: color(:hint),
        padding_top: 8
      )
    ]
  end

  defp provider_models(models) do
    Enum.flat_map(models, fn model ->
      [
        node(:box, height: 1, fill_width: true, background: color(:separator)),
        model_row(model)
      ]
    end)
  end

  defp provider_actions(provider) do
    fetch =
      if provider.fetchable do
        [secondary_button(gettext("Fetch models"), {:fetch_models, provider.id})]
      else
        []
      end

    fetch ++ [secondary_button(gettext("Edit provider"), {:edit_provider, provider.id})]
  end

  defp model_row(model) do
    enabled? = Map.get(model, :enabled, true)
    edit = {:edit_model, model.provider_id, model.model_id}

    node(
      :row,
      [
        fill_width: true,
        align: "center",
        padding_top: 10,
        padding_bottom: 4,
        on_tap: {self(), edit},
        id: "model-row-#{model.provider_id}-#{model.model_id}"
      ],
      [
        node(
          :column,
          [weight: 1, fill_width: true, on_tap: {self(), edit}],
          [
            text(model.name, text_size: 15, weight: 1, max_lines: 1),
            text(model.id, text_size: 12, text_color: color(:hint), max_lines: 1)
          ]
        ),
        node(
          :toggle,
          value: enabled?,
          on_change:
            {self(), {:toggle_model_enabled, model.provider_id, model.model_id, not enabled?}},
          id: "toggle-model-#{model.provider_id}-#{model.model_id}"
        )
      ]
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
