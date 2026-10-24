defmodule HandbeanWeb.Live.Settings.ModelAIPanel do
  @moduledoc """
  Model / AI settings panel content.

  Kept separate from the Settings shell so future settings sections do not
  accumulate in one large LiveView/HEEx module.
  """

  use HandbeanWeb, :html

  alias Handbean.Agent.Reasoning
  alias HandbeanWeb.Components.ModelPicker

  attr(:form, :map, required: true)
  attr(:available_models, :list, required: true)
  attr(:errors, :map, required: true)
  attr(:target, :any, default: nil)
  attr(:scope, :any, default: :global)

  def render(assigns) do
    target_attrs = if assigns.target, do: %{:"phx-target" => assigns.target}, else: %{}
    assigns = assign(assigns, :target_attrs, target_attrs)

    ~H"""
    <form {@target_attrs} class="settings-model-ai-form">
      <section class="settings-model-section">
        <div class="settings-model-section-header">
          <h4 class="settings-model-section-title">
            {gettext("Model")}
          </h4>
          <span
            :if={@scope != :global}
            class="text-xs text-warning bg-warning-subtle px-2 py-1 rounded"
          >
            {gettext("workspace override")}
          </span>
        </div>
        <div class="settings-card settings-card-has-model-picker">
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Default model")}</div>
              <div class="settings-field-desc">
                {gettext("Used for new conversations unless a workspace default overrides it.")}
              </div>
            </div>
            <div class="settings-field-control">
              <ModelPicker.render
                id="default-model-picker"
                name="default_model"
                value={@form.default_model}
                options={
                  model_picker_options(
                    @available_models,
                    @form.default_model,
                    gettext("None (use provider default)")
                  )
                }
                label={gettext("Default model")}
                change="update_field"
                target={@target}
              />
            </div>
          </div>
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Reasoning")}</div>
              <div class="settings-field-desc">
                {gettext("How much internal reasoning the model should use.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="reasoning"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="off" selected={@form.reasoning == "off"}>
                  {gettext("None (use provider default)")}
                </option>
                <option value="minimal" selected={@form.reasoning == "minimal"}>
                  {gettext("Minimal")}
                </option>
                <option value="low" selected={@form.reasoning == "low"}>{gettext("Low")}</option>
                <option value="medium" selected={@form.reasoning == "medium"}>
                  {gettext("Medium")}
                </option>
                <option value="high" selected={@form.reasoning == "high"}>{gettext("High")}</option>
                <option value="xhigh" selected={@form.reasoning == "xhigh"}>
                  {gettext("X-High")}
                </option>
              </select>
            </div>
          </div>
        </div>
      </section>

      <section class="settings-model-section">
        <h4 class="settings-model-section-title">{gettext("Advisor")}</h4>
        <div class="settings-card settings-card-has-model-picker">
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Advisor model")}</div>
              <div class="settings-field-desc">
                {gettext(
                  "Optional second model. When set, the agent can ask it for advice and decides for itself when to call."
                )}
              </div>
            </div>
            <div class="settings-field-control">
              <ModelPicker.render
                id="advisor-model-picker"
                name="advisor_model"
                value={@form.advisor_model}
                options={
                  model_picker_options(
                    @available_models,
                    @form.advisor_model,
                    if(@scope == :global,
                      do: gettext("Not configured"),
                      else: gettext("No workspace model")
                    )
                  )
                }
                label={gettext("Advisor model")}
                change="update_field"
                target={@target}
              />
            </div>
          </div>
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Think level")}</div>
              <div class="settings-field-desc">
                {gettext("Reasoning level used by the advisor model.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select name="advisor_reasoning" phx-change="update_field" class="settings-input">
                <option value="" selected={is_nil(@form.advisor_reasoning)}>
                  {gettext("Model default")}
                </option>
                <option
                  :if={
                    missing_reasoning?(
                      @form.advisor_reasoning,
                      @available_models,
                      @form.advisor_model
                    )
                  }
                  value={@form.advisor_reasoning}
                  selected
                >
                  {unavailable_reasoning_label(@form.advisor_reasoning)}
                </option>
                <option
                  :for={level <- reasoning_levels(@available_models, @form.advisor_model)}
                  value={level}
                  selected={@form.advisor_reasoning == level}
                >
                  {reasoning_label(level)}
                </option>
              </select>
            </div>
          </div>
          <div :if={@scope != :global} class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Workspace advisor")}</div>
              <div class="settings-field-desc">
                {gettext("Inherit the global advisor, choose another model, or turn it off here.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select name="advisor_setting" phx-change="update_field" class="settings-input">
                <option value="inherit" selected={@form.advisor_mode == :inherit}>
                  {gettext("Use global")}
                </option>
                <option value="custom" selected={@form.advisor_mode == :custom}>
                  {gettext("Use the model selected above")}
                </option>
                <option value="disabled" selected={@form.advisor_mode == :disabled}>
                  {gettext("Disabled")}
                </option>
              </select>
            </div>
          </div>
        </div>
      </section>

      <section class="settings-model-section">
        <h4 class="settings-model-section-title">{gettext("Subagent")}</h4>
        <div class="settings-card settings-card-has-model-picker">
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Subagent model")}</div>
              <div class="settings-field-desc">
                {gettext(
                  "Used by the task tool. Does not affect create_conversation. Follow current conversation unless you pick a model."
                )}
              </div>
            </div>
            <div class="settings-field-control">
              <ModelPicker.render
                id="subagent-model-picker"
                name="subagent_model"
                value={@form.subagent_model}
                options={
                  model_picker_options(
                    @available_models,
                    @form.subagent_model,
                    gettext("Follow current conversation")
                  )
                }
                label={gettext("Subagent model")}
                change="update_field"
                target={@target}
              />
            </div>
          </div>
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Think level")}</div>
              <div class="settings-field-desc">
                {gettext("Think level for the subagent default model.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select name="subagent_reasoning" phx-change="update_field" class="settings-input">
                <option value="" selected={is_nil(@form.subagent_reasoning)}>
                  {gettext("Model default")}
                </option>
                <option
                  :if={
                    missing_reasoning?(
                      @form.subagent_reasoning,
                      @available_models,
                      @form.subagent_model
                    )
                  }
                  value={@form.subagent_reasoning}
                  selected
                >
                  {unavailable_reasoning_label(@form.subagent_reasoning)}
                </option>
                <option
                  :for={level <- reasoning_levels(@available_models, @form.subagent_model)}
                  value={level}
                  selected={@form.subagent_reasoning == level}
                >
                  {reasoning_label(level)}
                </option>
              </select>
            </div>
          </div>
        </div>
      </section>

      <section class="settings-model-section">
        <h4 class="settings-model-section-title">
          {gettext("Memory Reflection")}
        </h4>
        <div class="settings-card settings-card-has-model-picker">
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <label
                id="memory-reflection-toggle-label"
                for="memory-reflection-toggle"
                class="settings-field-title"
              >
                {gettext("Enable memory reflection")}
              </label>
              <div id="memory-reflection-toggle-desc" class="settings-field-desc">
                {gettext("Compaction produces reviewable memory candidates when enabled.")}
              </div>
            </div>
            <div class="settings-field-control">
              <label class="relative inline-flex items-center cursor-pointer h-4 shrink-0">
                <input
                  id="memory-reflection-toggle"
                  type="checkbox"
                  checked={@form.om_reflector_enabled}
                  phx-click="toggle_reflector"
                  aria-labelledby="memory-reflection-toggle-label"
                  aria-describedby="memory-reflection-toggle-desc"
                  class="sr-only peer"
                />
                <span class="settings-toggle-track">
                  <span class="settings-toggle-thumb"></span>
                </span>
              </label>
            </div>
          </div>
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Memory model")}</div>
              <div class="settings-field-desc">
                {gettext(
                  "Used to generate reviewable memory candidates from compacted conversations."
                )}
              </div>
            </div>
            <div class="settings-field-control">
              <ModelPicker.render
                id="memory-model-picker"
                name="om_model"
                value={@form.om_model}
                options={
                  model_picker_options(
                    @available_models,
                    @form.om_model,
                    gettext("Same as default model")
                  )
                }
                label={gettext("Memory model")}
                change="update_field"
                target={@target}
              />
            </div>
          </div>
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Think level")}</div>
              <div class="settings-field-desc">
                {gettext("Reasoning level used for memory reflection.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="om_reasoning"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="" selected={is_nil(@form.om_reasoning)}>
                  {gettext("Model default")}
                </option>
                <option
                  :if={
                    missing_reasoning?(
                      @form.om_reasoning,
                      @available_models,
                      @form.om_model || @form.default_model
                    )
                  }
                  value={@form.om_reasoning}
                  selected
                >
                  {unavailable_reasoning_label(@form.om_reasoning)}
                </option>
                <option
                  :for={
                    level <-
                      reasoning_levels(@available_models, @form.om_model || @form.default_model)
                  }
                  value={level}
                  selected={@form.om_reasoning == level}
                >
                  {reasoning_label(level)}
                </option>
              </select>
            </div>
          </div>

          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Memory scope")}</div>
              <div class="settings-field-desc">
                {gettext("Where extracted memories are stored.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="om_memory_scope"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="workspace" selected={@form.om_memory_scope == "workspace"}>
                  {gettext("Workspace only")}
                </option>
                <option value="global" selected={@form.om_memory_scope == "global"}>
                  {gettext("Global")}
                </option>
                <option value="both" selected={@form.om_memory_scope == "both"}>
                  {gettext("Both")}
                </option>
              </select>
            </div>
          </div>
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Privacy mode")}</div>
              <div class="settings-field-desc">
                {gettext("How isolated memory processing should be.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="om_privacy_mode"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="standard" selected={@form.om_privacy_mode == "standard"}>
                  {gettext("Standard")}
                </option>
                <option value="local_only" selected={@form.om_privacy_mode == "local_only"}>
                  {gettext("Data isolated")}
                </option>
              </select>
            </div>
          </div>
        </div>
      </section>

      <div :if={@errors != %{}} class="bg-error-subtle border rounded-lg p-3 text-sm text-error">
        <p :for={{_k, msg} <- @errors}>{msg}</p>
      </div>
    </form>
    """
  end

  defp model_picker_options(models, selected, empty_label) do
    empty = [ModelPicker.option("", empty_label)]

    unavailable =
      if missing_model?(selected, models) do
        [
          ModelPicker.option(
            selected,
            unavailable_model_label(selected),
            model_provider(selected)
          )
        ]
      else
        []
      end

    available =
      Enum.map(models, fn model ->
        ModelPicker.option(
          model_value(model),
          model_display(model),
          model_provider(model_value(model))
        )
      end)

    empty ++ unavailable ++ available
  end

  defp model_provider(model_id) when is_binary(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [provider, _model] -> provider
      _ -> nil
    end
  end

  defp model_provider(_model_id), do: nil

  defp model_value(m) when is_map(m) do
    provider = Handbean.Utils.SafeMap.get_any(m, :provider, "provider")
    model = Handbean.Utils.SafeMap.get_any(m, :model, "model")
    provider_id = Handbean.Utils.SafeMap.get_any(m, :provider_id, "provider_id")
    model_id = Handbean.Utils.SafeMap.get_any(m, :model_id, "model_id")
    id = Handbean.Utils.SafeMap.get_any(m, :id, "id")

    cond do
      provider && model -> "#{provider}/#{model}"
      provider_id && model_id -> "#{provider_id}/#{model_id}"
      id -> id
      true -> ""
    end
  end

  defp model_value(str) when is_binary(str), do: str
  defp model_value(_), do: ""

  defp model_display(m) when is_map(m) do
    provider = Handbean.Utils.SafeMap.get_any(m, :provider, "provider")
    model = Handbean.Utils.SafeMap.get_any(m, :model, "model")
    provider_id = Handbean.Utils.SafeMap.get_any(m, :provider_id, "provider_id")
    model_id = Handbean.Utils.SafeMap.get_any(m, :model_id, "model_id")
    id = Handbean.Utils.SafeMap.get_any(m, :id, "id")
    name = Handbean.Utils.SafeMap.get_any(m, :name, "name")

    cond do
      provider && model -> "#{provider} / #{model}"
      provider_id && (name || model_id) -> "#{provider_id} / #{name || model_id}"
      id -> name || id
      true -> ""
    end
  end

  defp model_display(str) when is_binary(str), do: str
  defp model_display(_), do: ""

  defp reasoning_levels(models, model_id) do
    case Enum.find(models, &(model_value(&1) == model_id)) do
      nil -> []
      model -> Reasoning.supported_levels(model)
    end
  end

  defp missing_model?(model_id, models) when is_binary(model_id) and model_id != "" do
    Enum.all?(models, &(model_value(&1) != model_id))
  end

  defp missing_model?(_model_id, _models), do: false

  defp missing_reasoning?(reasoning, models, model_id)
       when is_binary(reasoning) and reasoning != "" do
    reasoning not in reasoning_levels(models, model_id)
  end

  defp missing_reasoning?(_reasoning, _models, _model_id), do: false

  defp unavailable_model_label(model_id),
    do: gettext("%{model} (Unavailable)", model: model_id)

  defp unavailable_reasoning_label(reasoning),
    do: gettext("%{level} (Unavailable)", level: reasoning_label(reasoning))

  defp reasoning_label("off"), do: gettext("None (use provider default)")
  defp reasoning_label("minimal"), do: gettext("Minimal")
  defp reasoning_label("low"), do: gettext("Low")
  defp reasoning_label("medium"), do: gettext("Medium")
  defp reasoning_label("high"), do: gettext("High")
  defp reasoning_label("xhigh"), do: gettext("X-High")
  defp reasoning_label(level), do: level
end
