defmodule HandbeanProbe.ModelSettings.RenderConfirm do
  @moduledoc "Delete confirmation sheet for the native model settings."

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI
  import HandbeanProbe.ModelSettings.Render, only: [settings_select: 3]
  alias Handbean.Settings.ModelRefs
  alias HandbeanProbe.ModelSettings.{Labels, Providers}

  def confirm_sheet(%{confirm: nil}), do: nil

  def confirm_sheet(%{confirm: %{kind: :delete_model} = confirm} = state) do
    delete_confirm(gettext("Delete model %{model}?", model: confirm.model), confirm, state)
  end

  def confirm_sheet(%{confirm: %{kind: :delete_provider} = confirm} = state) do
    delete_confirm(
      gettext("Delete provider %{provider} and its %{count} models?",
        provider: Providers.label(state, confirm.provider),
        count: confirm.models_count
      ),
      confirm,
      state
    )
  end

  defp delete_confirm(title, confirm, state) do
    refs = confirm.refs
    last_model? = confirm[:last_model?] == true
    last_provider? = confirm[:last_provider?] == true
    blocked_last? = last_model? or last_provider?
    blocking = ModelRefs.blocking(refs)
    can_delete? = not blocked_last? and (blocking == [] or is_binary(confirm.replacement))
    ref_errors = length(confirm[:ref_errors] || [])

    frame(
      title,
      [
        if(last_model?,
          do: text(gettext("This is the provider's only model. Delete the provider instead."))
        ),
        if(last_provider?,
          do: text(gettext("This is the only provider. The catalog must keep at least one."))
        ),
        if(blocking == [],
          do: text(gettext("No settings reference this entry.")),
          else:
            node(
              :column,
              [fill_width: true],
              [text(gettext("Still referenced. Choose a replacement, then confirm."))] ++
                Enum.map(refs, &text(Labels.ref(&1), text_size: 12, text_color: color(:hint))) ++
                [
                  gap(),
                  settings_select(
                    confirm.replacement || gettext("Select replacement"),
                    replacement_options(state),
                    "select-replacement"
                  )
                ]
            )
        ),
        if(ref_errors > 0,
          do:
            text(Labels.ref_errors(ref_errors),
              id: "settings-confirm-ref-errors",
              text_size: 12,
              text_color: color(:hint),
              padding_top: 4
            )
        )
      ],
      actions_row([
        if(can_delete?,
          do:
            danger_button(gettext("Confirm delete"), :confirm_delete, weight: 1, fill_width: true),
          else:
            text(gettext("Confirm delete is unavailable"),
              text_size: 13,
              text_color: color(:hint),
              padding: 10,
              weight: 1
            )
        ),
        secondary_button(gettext("Cancel"), :cancel_confirm, weight: 1, fill_width: true)
      ])
    )
  end

  defp frame(title, body, actions) do
    # Content detent + no weighted scroll: medium+large would present this
    # column at half height, and weight:1 on the body expands into that
    # viewport so Cancel/Confirm land below the fold (settings-final-delete-dialog).
    # MobSheet then scrolls overflow itself when the body is long.
    sheet(
      node(:column, [fill_width: true, padding: 16], [
        text(title, text_size: 17, padding_bottom: 8),
        node(
          :column,
          [id: "settings-confirm-body", fill_width: true],
          Enum.reject(List.wrap(body), &is_nil/1)
        ),
        gap(),
        actions
      ]),
      id: "settings-confirm",
      detents: [:content]
    )
  end

  defp replacement_options(state) do
    Enum.map(
      state.models,
      &select_option(
        &1.id,
        {:replacement, &1.id},
        state.confirm && state.confirm.replacement == &1.id
      )
    )
  end
end
