defmodule HandbeanProbe.NativeModelInputs do
  @moduledoc "Native composer input-capability checks and their dismissible warning sheet."
  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI
  alias Handbean.Agent.ModelCapabilities
  alias HandbeanProbe.NativeLocalImage

  def required_inputs(attachments) do
    if Enum.any?(attachments, &NativeLocalImage.image_attachment?/1), do: ["image"], else: []
  end

  def warning(assigns, inputs \\ nil) do
    models = assigns.models
    selected = Enum.find(models.allowed_models, &(&1.id == models.default))

    case ModelCapabilities.validate_inputs(
           selected,
           inputs || required_inputs(assigns.pending_attachments)
         ) do
      :ok ->
        nil

      {:error, {:model_input, type, status}} ->
        %{
          model:
            if(selected, do: selected.name, else: models.default || gettext("No model selected")),
          type: type,
          status: status
        }
    end
  end

  def check(socket, inputs \\ nil) do
    Mob.Socket.assign(socket, :input_warning, warning(socket.assigns, inputs))
  end

  def render(nil), do: nil

  def render(warning) do
    sheet(
      node(:column, [fill_width: true, padding: 16], [
        text(gettext("Model input not supported"), text_size: 17),
        text(message(warning), padding_top: 8, padding_bottom: 12),
        button(gettext("Got it"), :dismiss_input_warning, fill_width: true)
      ]),
      id: "model-input-warning",
      detents: [:content],
      dismiss: :dismiss_input_warning
    )
  end

  defp message(%{model: model, status: :unknown}) do
    gettext(
      "%{model} has no declared image input capability. Choose a model that supports images, or configure its input capabilities. Your draft is kept.",
      model: model
    )
  end

  defp message(%{model: model, type: "image"}) do
    gettext(
      "%{model} does not support image input. Switch to a model that supports images or remove the images before sending. Your draft is kept.",
      model: model
    )
  end
end
