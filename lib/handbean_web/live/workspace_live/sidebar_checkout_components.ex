defmodule HandbeanWeb.WorkspaceLive.SidebarCheckoutComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.Components.ModelPicker
  alias HandbeanWeb.WorkspaceLive.ModelSelection

  import HandbeanWeb.WorkspaceLive.ViewComponents

  attr :workspace_id, :string, required: true
  attr :draft, :any, default: nil
  attr :source, :atom, default: :sidebar

  def checkout_picker(assigns) do
    open? =
      match?(
        %{workspace_id: workspace_id, source: source}
        when workspace_id == assigns.workspace_id and source == assigns.source,
        assigns.draft
      )

    click =
      if assigns.source == :mobile,
        do: "mobile_new_conversation_in_workspace",
        else: "new_conversation_in_workspace"

    assigns =
      assigns
      |> assign(:open?, open?)
      |> assign(:click, click)

    ~H"""
    <div class="workspace-checkout-picker">
      <button
        type="button"
        phx-click={@click}
        phx-value-ws_id={@workspace_id}
        class={[
          @source != :mobile &&
            "workspace-add-btn flex-shrink-0 w-5 h-5 flex items-center justify-center rounded text-tertiary hover:text-primary hover:bg-surface-hover transition-colors",
          @source == :mobile && "sheet-new-conv-btn",
          @open? && "is-open"
        ]}
        title={gettext("在此工作区新建对话")}
        aria-label={gettext("在此工作区新建对话")}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open?)}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path
            d="M6 1v10M1 6h10"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
          />
        </svg>
      </button>
    </div>
    """
  end

  attr :draft, :any, default: nil
  attr :uploads, :any, required: true
  attr :composer_error, :any, default: nil

  def new_conversation_page(assigns) do
    ~H"""
    <div
      :if={@draft}
      id="new-conversation-page"
      class="new-conversation-page"
      phx-window-keydown="close_new_conversation"
      phx-key="Escape"
      aria-label={gettext("新建对话")}
    >
      <div class="new-conversation-stage">
        <h1 class="new-conversation-heading">{gettext("从一条消息开始")}</h1>
        <div class="composer-dock">
          <form
            id="new-conversation-composer"
            phx-submit="submit_new_conversation"
            phx-change="update_new_conversation_draft"
            phx-drop-target={@uploads.images.ref}
            class="composer dropzone"
          >
            <input type="hidden" name="draft_id" value={@draft.id} />

            <div :if={@draft.error || @composer_error} class="composer-error" role="alert">
              <span class="truncate">{@draft.error || @composer_error}</span>
              <button :if={@composer_error} type="button" phx-click="clear_composer_error">
                {gettext("关闭")}
              </button>
            </div>

            <div class="composer-turn-controls">
              <div class="composer-turn-pickers">
                <div :if={@draft.models != []} class="model-control">
                  <ModelPicker.render
                    id="new-conversation-model-picker"
                    name="model"
                    value={@draft.model}
                    options={model_options(@draft.models)}
                    label={gettext("模型")}
                    title={gettext("选择新对话使用的模型")}
                    change="update_new_conversation_draft"
                    compact
                  />
                </div>
                <div :if={@draft.reasoning_levels != []} class="model-control">
                  <select
                    id="new-conversation-reasoning"
                    name="reasoning"
                    value={@draft.reasoning}
                    phx-hook="BoundSelect"
                    data-value={@draft.reasoning || ""}
                    phx-change="update_new_conversation_draft"
                    aria-label={gettext("推理等级")}
                    title={gettext("推理等级")}
                  >
                    <option
                      :for={level <- @draft.reasoning_levels}
                      value={level}
                      selected={level == @draft.reasoning}
                    >
                      {reasoning_label(level)}
                    </option>
                  </select>
                </div>
              </div>
              <div class="permission-menu-container">
                <select
                  id="new-conversation-permission"
                  name="permission_mode"
                  value={@draft.permission_mode}
                  phx-hook="BoundSelect"
                  data-value={to_string(@draft.permission_mode)}
                  phx-change="update_new_conversation_draft"
                  aria-label={gettext("权限")}
                  title={permission_title(@draft.permission_mode)}
                  class="pill new-conversation-permission"
                >
                  <option
                    :for={mode <- [:prompt, :auto_review, :yolo]}
                    value={mode}
                    selected={mode == @draft.permission_mode}
                  >
                    {permission_label(mode)}
                  </option>
                </select>
              </div>
            </div>

            <div class="composer-bar">
              <div class="textarea-wrap">
                <label class="sr-only" for="new-conversation-message">{gettext("消息")}</label>
                <textarea
                  id="new-conversation-message"
                  name="message"
                  rows="1"
                  value={@draft.message}
                  placeholder={gettext("输入消息")}
                  phx-debounce="120"
                  phx-hook="ComposerPasteUpload"
                  data-upload-name="images"
                  autofocus
                >{Phoenix.HTML.Form.normalize_value("textarea", @draft.message)}</textarea>
              </div>
              <div class="composer-toolbar">
                <div
                  id="new-conversation-attachments"
                  class={[
                    "composer-thumbs",
                    @uploads.images.entries != [] && "visible"
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
                </div>

                <div class="composer-toolbar-actions">
                  <label
                    id="new-conversation-attachment-button"
                    class="composer-icon-btn"
                    title={gettext("添加图片")}
                  >
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
                    id="new-conversation-send"
                    type="submit"
                    phx-disable-with="…"
                    class="composer-send-btn primary"
                    disabled={@draft.models == []}
                    title={gettext("Send")}
                    aria-label={gettext("Send")}
                  >
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
                  </button>
                </div>
              </div>
            </div>
          </form>

          <div class="new-conversation-chips">
            <button
              :if={@draft.projects != []}
              type="button"
              class="new-conversation-chip"
              phx-click="toggle_new_conversation_projects"
              aria-expanded={to_string(@draft.project_menu_open?)}
              aria-controls="new-conversation-projects"
            >
              <.folder_icon />
              <span>{@draft.workspace_name}</span>
            </button>

            <span :if={@draft.projects == []} class="new-conversation-chip is-static">
              <.folder_icon />
              <span>{@draft.workspace_name}</span>
            </span>

            <label :if={length(@draft.checkouts) > 1} class="new-conversation-chip">
              <span class="sr-only">{gettext("Choose a checkout")}</span>
              <.branch_icon />
              <select
                id="new-conversation-checkout"
                name="checkout_path"
                form="new-conversation-composer"
                value={@draft.checkout_path}
                phx-change="select_new_conversation_checkout"
                aria-label={gettext("Choose a checkout")}
              >
                <option
                  :for={checkout <- @draft.checkouts}
                  value={checkout.path}
                  selected={checkout.path == @draft.checkout_path}
                >
                  {checkout_label(checkout)}
                </option>
              </select>
            </label>

            <div
              :if={@draft.project_menu_open? and @draft.projects != []}
              id="new-conversation-projects"
              class="new-conversation-projects"
            >
              <div class="new-conversation-projects-label">{gettext("选择项目")}</div>
              <button
                :for={project <- @draft.projects}
                id={"new-conversation-project-#{project.id}"}
                type="button"
                phx-click="select_new_conversation_project"
                phx-value-ws_id={project.id}
                class={[
                  "new-conversation-project",
                  project.id == @draft.workspace_id && "is-selected"
                ]}
                title={project.path}
              >
                <span class="new-conversation-project-name">{project.name}</span>
                <span class="new-conversation-project-path">{short_path(project.path)}</span>
                <span :if={project.id == @draft.workspace_id} class="new-conversation-project-check">
                  ✓
                </span>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp model_options(models) do
    models
    |> ModelSelection.models_by_provider()
    |> Enum.flat_map(fn {provider_id, provider_models} ->
      group = ModelSelection.provider_display_name(provider_id)

      Enum.map(provider_models, fn model ->
        ModelPicker.option(
          model.id,
          ModelSelection.model_option_label(model, provider_models),
          group
        )
      end)
    end)
  end

  defp checkout_label(%{branch: branch, path: path}) when is_binary(branch) and branch != "",
    do: "#{branch} · #{Path.basename(path)}"

  defp checkout_label(%{detached?: true, path: path}), do: "detached · #{Path.basename(path)}"
  defp checkout_label(%{path: path}), do: Path.basename(path)

  defp short_path(path) when is_binary(path) do
    home = System.user_home!()

    if String.starts_with?(path, home <> "/") do
      "~/" <> String.replace_prefix(path, home <> "/", "")
    else
      path
    end
  end

  defp short_path(_path), do: ""

  defp folder_icon(assigns) do
    ~H"""
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    </svg>
    """
  end

  defp branch_icon(assigns) do
    ~H"""
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <line x1="6" y1="3" x2="6" y2="15" />
      <circle cx="18" cy="6" r="3" />
      <circle cx="6" cy="18" r="3" />
      <path d="M18 9a9 9 0 0 1-9 9" />
    </svg>
    """
  end
end
