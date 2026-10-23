defmodule HandbeanWeb.WorkspaceLive.ChatComposerComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.Components.ModelPicker

  import HandbeanWeb.WorkspaceLive.ViewComponents

  attr :available_clis, :list, required: true
  attr :available_models, :list, required: true
  attr :available_reasoning_levels, :list, required: true
  attr :chat_scope, :any, required: true
  attr :channel_binding, :any, default: nil
  attr :cli_models_error, :any, required: true
  attr :cli_models_loading, :boolean, required: true
  attr :composer_error, :any, required: true
  attr :current_conversation_id, :any, required: true
  attr :input_value, :any, required: true
  attr :pending_attachments, :list, required: true
  attr :permission_mode, :any, required: true
  attr :running, :boolean, required: true
  attr :selected_cli, :any, required: true
  attr :selected_model, :any, required: true
  attr :selected_reasoning_level, :any, required: true
  attr :show_permission_menu, :boolean, required: true
  attr :skill_suggestions, :any, required: true
  attr :speech_available?, :boolean, required: true
  attr :speech_state, :any, required: true
  attr :uploads, :any, required: true
  attr :workspace_path, :any, required: true

  def composer(assigns) do
    ~H"""
    <!-- Input area -->
    <div id="ai-input-area" class="composer-dock">
      <form
        id="composer"
        phx-submit="send_message"
        phx-drop-target={@uploads.images.ref}
        phx-change="composer_drop"
        class={["composer dropzone", if(@running, do: "composer-running", else: "")]}
      >
        <input type="hidden" name="workspace_command_operation_id" value="" />
        <div
          :if={@composer_error}
          class="composer-error"
        >
          <span class="truncate">{@composer_error}</span>
          <button type="button" phx-click="clear_composer_error">
            dismiss
          </button>
        </div>

        <div class="composer-turn-controls">
          <div class="composer-turn-pickers">
            <span
              :if={channel_name(@channel_binding)}
              id="conversation-channel-binding"
              class="pill channel-binding-pill"
              data-channel={channel_name(@channel_binding)}
              aria-label={channel_binding_title(@channel_binding)}
              title={channel_binding_title(@channel_binding)}
            >
              <span aria-hidden="true">●</span>
              {channel_label(@channel_binding)}
            </span>
            <div :if={@available_clis != []} class="model-control">
              <select
                id="cli-picker"
                name="cli"
                phx-hook="BoundSelect"
                data-value={HandbeanWeb.WorkspaceLive.CliSelection.form_value(@selected_cli)}
                phx-change="select_cli"
                aria-label={gettext("CLI")}
                title={gettext("Handbean owns the turn unless a CLI is selected")}
              >
                <option value="" selected={is_nil(@selected_cli)}>
                  {gettext("Handbean")}
                </option>
                <option
                  :for={cli <- @available_clis}
                  value={cli.id}
                  selected={is_binary(@selected_cli) and cli.id == @selected_cli}
                >
                  {HandbeanWeb.WorkspaceLive.CliSelection.display_name(cli.id)}
                </option>
              </select>
            </div>
            <div :if={@cli_models_error} id="cli-models-error" class="composer-model-error">
              {HandbeanWeb.WorkspaceLive.CliSelection.error_message(@cli_models_error)}
            </div>
            <div :if={is_nil(@selected_cli) and @available_models != []} class="model-control">
              <ModelPicker.render
                id="model-picker"
                name="model"
                value={@selected_model}
                options={composer_model_options(@available_models)}
                label={gettext("模型")}
                title={gettext("可在对话中途更换模型")}
                change="select_model"
                refresh="refresh_models"
                compact
              />
            </div>
            <div :if={is_binary(@selected_cli) and @available_models != []} class="model-control">
              <ModelPicker.render
                id="cli-model-picker"
                name="model"
                value={@selected_model}
                options={cli_model_options(@available_models)}
                label={gettext("CLI model")}
                change="select_model"
                compact
              />
            </div>
            <div :if={@available_reasoning_levels != []} class="model-control">
              <select
                id="reasoning-picker"
                name="reasoning"
                value={@selected_reasoning_level}
                phx-hook="BoundSelect"
                data-value={@selected_reasoning_level || ""}
                phx-change="select_reasoning"
                aria-label={gettext("推理等级")}
                title={gettext("推理等级")}
              >
                <option
                  :for={level <- @available_reasoning_levels}
                  value={level}
                  selected={level == @selected_reasoning_level}
                >
                  {reasoning_label(level)}
                </option>
              </select>
            </div>
          </div>
          <div
            :if={@cli_models_loading}
            id="cli-models-loading"
            class="flex items-center gap-1.5 text-[11px] leading-[1.3] text-tertiary"
            role="status"
          >
            <span class="loading loading-spinner loading-xs" aria-hidden="true"></span>
            {gettext("Loading CLI models…")}
          </div>
          <div
            :if={
              @available_models == [] and is_nil(@cli_models_error) and
                not @cli_models_loading
            }
            class="composer-model-error"
          >
            {model_empty_message(@workspace_path)}
          </div>
          <div :if={@chat_scope != :free} class="permission-menu-container">
            <button
              type="button"
              class="pill"
              phx-click="toggle_permission_menu"
              title={permission_title(@permission_mode)}
            >
              {permission_label(@permission_mode)} ▾
            </button>
            <div
              :if={@show_permission_menu}
              phx-click-away="close_sheets"
              class="permission-dropdown-menu"
            >
              <button
                :for={
                  {mode, label} <- [
                    {:prompt, gettext("安全模式")},
                    {:auto_review, gettext("智能审批")},
                    {:yolo, gettext("yolo")}
                  ]
                }
                type="button"
                phx-click="select_permission_mode"
                phx-value-mode={mode}
                class={["permission-dropdown-item", if(@permission_mode == mode, do: "active")]}
                title={permission_title(mode)}
              >
                {label}
              </button>
            </div>
          </div>
        </div>

        <div class="composer-bar">
          <div
            id="composer-speech"
            class={["textarea-wrap", @speech_available? && "speech-enabled"]}
            phx-hook={if(@speech_available?, do: "ComposerSpeech")}
            data-speech-upload-name="speech_audio"
            data-speech-state={@speech_state}
            data-label-start={gettext("Start voice input")}
            data-label-stop={gettext("Stop recording")}
            data-label-processing={gettext("Transcribing voice")}
          >
            <label class="sr-only" for="ai-input">{gettext("消息")}</label>
            <textarea
              id="ai-input"
              name="message"
              rows="1"
              phx-keyup="update_input"
              phx-value-value={@input_value}
              phx-hook="ComposerPasteUpload"
              data-upload-name="images"
              data-command-intent-key="handbean:workspace-command-intent"
              data-command-intent-scope={
                @current_conversation_id || "new:#{@workspace_path || @chat_scope}"
              }
              placeholder={
                if(@running,
                  do: gettext("Running: send inserts next · queue waits until this run finishes"),
                  else: gettext("输入消息")
                )
              }
            >{Phoenix.HTML.Form.normalize_value("textarea", @input_value)}</textarea>

            <button
              :if={@speech_available?}
              id="speech-input-button"
              type="button"
              class="speech-input-button"
              disabled={@speech_state in [:processing, :downloading, :loading, :transcribing]}
              data-state={@speech_state}
              aria-label={gettext("Start voice input")}
              aria-pressed="false"
              title={gettext("Start voice input")}
            >
              <svg
                class="speech-input-mic"
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <rect x="9" y="3" width="6" height="11" rx="3" />
                <path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21M9 21h6" />
              </svg>
              <span class="speech-input-stop" aria-hidden="true"></span>
            </button>
            <.live_file_input upload={@uploads.speech_audio} class="hidden" />

            <div
              :if={@skill_suggestions not in [nil, []]}
              id="skill-suggestions"
              class="skill-suggestions-dropdown"
              phx-click-away="dismiss_skill_suggestions"
            >
              <div
                :for={skill <- @skill_suggestions}
                class="skill-suggestion-item"
              >
                <button
                  type="button"
                  phx-click="select_skill_suggestion"
                  phx-value-name={skill.name}
                  class="skill-suggestion-btn"
                >
                  <span class="skill-suggestion-name">{if String.starts_with?(skill.name, "/ext:"),
                    do: skill.name,
                    else: "/skill:#{skill.name}"}</span>
                  <span class="skill-suggestion-desc">{skill.description}</span>
                </button>
              </div>
            </div>
          </div>

          <div class="composer-toolbar">
            <div
              id="composer-attachments"
              class={[
                "composer-thumbs",
                if(@pending_attachments != [] or @uploads.images.entries != [],
                  do: "visible"
                )
              ]}
            >
              <div :for={entry <- @uploads.images.entries} class="composer-thumb">
                <.live_img_preview entry={entry} />
                <span class="sr-only">{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="composer-thumb-remove"
                  aria-label={gettext("移除 %{name}", name: entry.client_name)}
                >
                  ×
                </button>
              </div>
              <div :for={att <- @pending_attachments} class="composer-thumb">
                <img
                  src={Handbean.Utils.SafeMap.get_any(att, [:url, "url"])}
                  alt={Handbean.Utils.SafeMap.get_any(att, [:filename, "filename"])}
                />
                <button
                  type="button"
                  phx-click="remove_attachment"
                  phx-value-id={Handbean.Utils.SafeMap.get_any(att, [:id, "id"])}
                  class="composer-thumb-remove"
                  aria-label={
                    gettext("移除 %{name}",
                      name:
                        Handbean.Utils.SafeMap.get_any(att, [:filename, "filename"]) ||
                          gettext("附件")
                    )
                  }
                >
                  ×
                </button>
              </div>
            </div>

            <div
              id="composer-activity"
              class="composer-activity"
              data-active={to_string(@speech_state == :transcribing)}
              aria-hidden="true"
            >
              <span
                :for={index <- 1..28}
                class="composer-activity-dot"
                style={"--dot-index: #{index}"}
              ></span>
            </div>

            <div class="composer-toolbar-actions">
              <label class="composer-icon-btn" title={gettext("添加图片")}>
                <span class="sr-only">{gettext("添加图片")}</span>
                <svg
                  width="16"
                  height="16"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  aria-hidden="true"
                >
                  <path d="M21.44 11.05l-8.49 8.49a5.25 5.25 0 0 1-7.42-7.42l8.48-8.49a3.5 3.5 0 0 1 4.95 4.95l-8.48 8.49a1.75 1.75 0 1 1-2.47-2.47l7.78-7.78" />
                </svg>
                <.live_file_input upload={@uploads.images} class="hidden" />
              </label>

              <button
                :if={@running}
                type="button"
                phx-click="stop_run"
                class="composer-icon-btn composer-stop-btn"
                title={gettext("Stop")}
              >
                <span class="sr-only">{gettext("Stop")}</span>
                <span class="composer-stop-square" aria-hidden="true"></span>
              </button>
              <button
                :if={@running}
                id="queue-button"
                type="button"
                phx-click="queue_message"
                phx-value-message={@input_value}
                class="composer-icon-btn"
                title={gettext("When done")}
              >
                <span class="sr-only">{gettext("When done")}</span>
                <span aria-hidden="true">☰</span>
              </button>
              <button
                id="send-button"
                type="submit"
                form="composer"
                phx-disable-with="…"
                class={["composer-send-btn", if(@running, do: "steer", else: "primary")]}
                title={gettext("Send")}
              >
                <span class="sr-only">{gettext("Send")}</span>
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2.4"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  aria-hidden="true"
                >
                  <path d="M5 12h14" />
                  <path d="M13 6l6 6-6 6" />
                </svg>
                <span :if={@running} class="composer-steer-dot" aria-hidden="true"></span>
              </button>
            </div>
          </div>
        </div>
      </form>
    </div>
    """
  end

  defp channel_name(binding) when is_map(binding),
    do: Handbean.Utils.SafeMap.get(binding, "channel")

  defp channel_name(_binding), do: nil

  defp channel_label(binding) when is_map(binding),
    do: Handbean.Utils.SafeMap.get(binding, "label", channel_name(binding))

  defp channel_label(_binding), do: nil

  defp channel_binding_title(binding) do
    gettext(
      "This conversation is linked to the %{channel} channel. Only turns received from that channel are routed back to it.",
      channel: channel_label(binding)
    )
  end

  defp composer_model_options(models) do
    models
    |> models_by_provider()
    |> Enum.flat_map(fn {provider_id, provider_models} ->
      group = provider_display_name(provider_id)

      Enum.map(provider_models, fn model ->
        ModelPicker.option(model.id, model_option_label(model, provider_models), group)
      end)
    end)
  end

  defp cli_model_options(models) do
    Enum.map(models, fn model ->
      ModelPicker.option(model.id, model.display_name || model.id)
    end)
  end
end
