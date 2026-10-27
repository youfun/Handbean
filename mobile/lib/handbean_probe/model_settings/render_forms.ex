defmodule HandbeanProbe.ModelSettings.RenderForms do
  @moduledoc "Model and provider editor forms for the native model settings."

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI
  import HandbeanProbe.ModelSettings.Render, only: [settings_select: 3, help_block: 4]
  alias HandbeanProbe.ModelSettings.{Forms, Labels}

  def form(%{editing: :new_provider} = state), do: provider_editor(state)
  def form(%{editing: {:provider, _}} = state), do: provider_editor(state)
  def form(state), do: model_editor(state)

  defp model_editor(state) do
    f = state.form

    [
      settings_section(gettext("Model")),
      settings_group(
        [
          settings_value_row(gettext("Provider"), f.provider_name)
        ] ++
          catalog_model_picker(f) ++
          [
            if(state.editing == :new,
              do: field(gettext("Model name"), f.model, {:model_field, :model}),
              else: settings_value_row(gettext("Model"), f.model)
            ),
            if(state.editing == :new,
              do:
                text(gettext("Example: gpt-4o or claude-sonnet-4"),
                  text_size: 12,
                  text_color: color(:hint),
                  padding_left: 16,
                  padding_right: 16,
                  padding_bottom: 8
                )
            ),
            field(gettext("Display name"), f.name, {:model_field, :name})
          ]
      ),
      settings_section(gettext("Model limits")),
      settings_group([
        field(gettext("Context window"), f.context_window, {:model_field, :context_window},
          keyboard: "number"
        ),
        help_block(
          state,
          :context_window,
          gettext("Context window is stored as model metadata."),
          gettext("It does not change the conversation compaction budget.")
        ),
        field(gettext("Max output tokens"), f.max_tokens, {:model_field, :max_tokens},
          keyboard: "number"
        ),
        text(Labels.token_lines(state, f),
          text_size: 12,
          text_color: color(:hint),
          padding_left: 16,
          padding_right: 16,
          padding_bottom: 8
        ),
        settings_nav_row(
          gettext("Reasoning"),
          if(f.reasoning, do: gettext("On"), else: gettext("Off")),
          :model_reasoning
        )
      ]),
      form_actions(gettext("Save model"), :save_model)
    ]
  end

  defp catalog_model_picker(%{catalog_models: models} = form)
       when is_list(models) and models != [] do
    [
      settings_form_field(
        gettext("Known models"),
        settings_select(
          Forms.catalog_model_label(form),
          [select_option(gettext("Custom name"), {:catalog_model, ""}, form.model == "")] ++
            Enum.map(
              models,
              &select_option(&1.name, {:catalog_model, &1.id}, form.model == &1.id)
            ),
          "select-catalog-model"
        )
      )
    ]
  end

  defp catalog_model_picker(_form), do: []

  defp provider_editor(state) do
    f = state.form

    title =
      if(state.editing == :new_provider,
        do: gettext("New provider"),
        else: f.name || gettext("Provider")
      )

    [
      settings_section(title),
      settings_group([
        field(gettext("Display name"), f.name, {:model_field, :name}, grouped: true),
        field(gettext("Base URL (HTTPS)"), f.base_url, {:model_field, :base_url},
          grouped: true,
          keyboard: "url"
        ),
        field(
          gettext("API Key"),
          f.api_key,
          {:model_field, :api_key},
          grouped: true,
          secure: true,
          placeholder: f.key_preview || ""
        )
      ]),
      settings_section(gettext("API protocol")),
      settings_group([
        settings_form_field(
          gettext("API protocol"),
          settings_select(
            Labels.protocol(f.api),
            Enum.map(
              Forms.protocols(),
              &select_option(Labels.protocol(&1), {:api, &1}, f.api == &1)
            ),
            "select-protocol"
          )
        )
      ]),
      form_actions(gettext("Save provider"), :save_provider)
    ]
  end

  defp form_actions(save_label, save_tag) do
    settings_group([
      settings_nav_row(save_label, "", save_tag),
      settings_nav_row(gettext("Cancel"), "", :cancel_model, quiet: true)
    ])
  end
end
