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
      form_actions(gettext("Save model"), :save_model, :top),
      card(
        [
          text(gettext("Model"), text_size: 16, padding_bottom: 8),
          text(gettext("Provider: %{provider}", provider: f.provider_name), padding_bottom: 8)
        ] ++
          catalog_model_picker(f) ++
          [
            if(state.editing == :new,
              do: field(gettext("Model name"), f.model, {:model_field, :model}),
              else: text(gettext("Model: %{model}", model: f.model), padding_bottom: 8)
            ),
            if(state.editing == :new,
              do:
                text(gettext("Example: gpt-4o or claude-sonnet-4"),
                  text_size: 12,
                  text_color: color(:hint),
                  padding_bottom: 8
                )
            ),
            field(gettext("Display name"), f.name, {:model_field, :name})
          ]
      ),
      card([
        text(gettext("Model limits"), text_size: 16, padding_bottom: 8),
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
          padding_bottom: 8
        ),
        button(
          if(f.reasoning, do: gettext("Reasoning: enabled"), else: gettext("Reasoning: off")),
          :model_reasoning,
          fill_width: true
        )
      ]),
      form_actions(gettext("Save model"), :save_model, :bottom)
    ]
  end

  defp catalog_model_picker(%{catalog_models: models} = form)
       when is_list(models) and models != [] do
    [
      text(gettext("Known models"), text_size: 13, padding_bottom: 4),
      settings_select(
        Forms.catalog_model_label(form),
        [select_option(gettext("Custom name"), {:catalog_model, ""}, form.model == "")] ++
          Enum.map(
            models,
            &select_option(&1.name, {:catalog_model, &1.id}, form.model == &1.id)
          ),
        "select-catalog-model"
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
      form_actions(gettext("Save provider"), :save_provider, :top),
      card([
        text(title, text_size: 16, padding_bottom: 8),
        field(gettext("Display name"), f.name, {:model_field, :name}),
        field(gettext("Base URL (HTTPS)"), f.base_url, {:model_field, :base_url},
          keyboard: "url"
        ),
        field(
          gettext("API Key"),
          f.api_key,
          {:model_field, :api_key},
          secure: true
        ),
        text(Labels.key_status(f.key_status), text_size: 12, text_color: color(:hint)),
        help_block(
          state,
          :api_key,
          gettext("Saved keys are never shown again."),
          Labels.key_help(f.key_status)
        ),
        field(
          gettext("Provider max output tokens (override)"),
          f.provider_max_tokens,
          {:model_field, :provider_max_tokens},
          keyboard: "number"
        )
      ]),
      card([
        text(gettext("API protocol"), text_size: 16, padding_bottom: 8),
        settings_select(
          Labels.protocol(f.api),
          Enum.map(
            Forms.protocols(),
            &select_option(Labels.protocol(&1), {:api, &1}, f.api == &1)
          ),
          "select-protocol"
        )
      ]),
      form_actions(gettext("Save provider"), :save_provider, :bottom)
    ]
  end

  defp form_actions(save_label, save_tag, :bottom) do
    card(
      [
        actions_row([
          primary_button(save_label, save_tag, weight: 1, fill_width: true, text_align: "center"),
          secondary_button(gettext("Cancel"), :cancel_model,
            weight: 1,
            fill_width: true,
            text_align: "center"
          )
        ])
      ],
      padding: 12
    )
  end

  defp form_actions(save_label, save_tag, :top) do
    card(
      [
        actions_row([
          primary_button(save_label, save_tag,
            id: "#{save_tag}-top",
            weight: 1,
            fill_width: true,
            text_align: "center"
          ),
          secondary_button(gettext("Cancel"), :cancel_model,
            id: "cancel_model-top",
            weight: 1,
            fill_width: true,
            text_align: "center"
          )
        ])
      ],
      padding: 12
    )
  end
end
