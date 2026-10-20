defmodule HandbeanWeb.WorkspaceLive.ChatDialogComponents do
  @moduledoc false

  use HandbeanWeb, :html

  attr :add_project_form, :any, required: true
  attr :file_browser_path, :any, required: true
  attr :remove_workspace, :any, required: true
  attr :rename_conversation, :any, required: true
  attr :rename_workspace, :any, required: true
  attr :sandbox_workspace?, :boolean, required: true
  attr :show_add_project, :boolean, required: true
  attr :show_file_browser, :boolean, required: true

  def dialogs(assigns) do
    ~H"""
    <!-- Rename Conversation Dialog -->
    <div
      :if={@rename_conversation}
      id="rename-conversation-overlay"
      class="absolute inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="cancel_rename_conversation"
      phx-key="Escape"
    >
      <button
        type="button"
        class="absolute inset-0 bg-transparent border-0"
        phx-click="cancel_rename_conversation"
        aria-label={gettext("取消")}
      ></button>
      <form
        id="rename-conversation-dialog"
        phx-submit="confirm_rename_conversation"
        class="relative add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5"
      >
        <h3 class="text-base font-semibold text-primary mb-4">{gettext("重命名会话")}</h3>
        <div class="space-y-3 mb-4">
          <div>
            <label for="rename-conversation-input" class="text-xs text-secondary block mb-1">
              {gettext("会话名称")}
            </label>
            <input
              id="rename-conversation-input"
              type="text"
              name="title"
              value={@rename_conversation.title}
              phx-mounted={JS.focus()}
              maxlength="80"
              autocomplete="off"
              class="w-full bg-main border rounded px-2 py-1.5 text-xs text-primary focus:outline-none focus:border-accent"
            />
          </div>
          <div
            :if={@rename_conversation.error}
            id="rename-conversation-error"
            class="text-xs text-error bg-error-subtle rounded px-3 py-2"
          >
            {@rename_conversation.error}
          </div>
        </div>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel_rename_conversation"
            class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
          >
            {gettext("取消")}
          </button>
          <button
            type="submit"
            id="rename-conversation-submit"
            class="text-xs bg-user text-white rounded px-4 py-1.5 transition-colors hover:bg-user-hover"
          >
            {gettext("保存")}
          </button>
        </div>
      </form>
    </div>

    <div
      :if={@rename_workspace}
      id="rename-workspace-overlay"
      class="absolute inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="cancel_rename_workspace"
      phx-key="Escape"
    >
      <button
        type="button"
        class="absolute inset-0 bg-transparent border-0"
        phx-click="cancel_rename_workspace"
        aria-label={gettext("取消")}
      ></button>
      <form
        id="rename-workspace-dialog"
        phx-submit="confirm_rename_workspace"
        class="relative add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5"
      >
        <h3 class="text-base font-semibold text-primary mb-4">{gettext("重命名工作区")}</h3>
        <div class="space-y-3 mb-4">
          <div>
            <label for="rename-workspace-input" class="text-xs text-secondary block mb-1">
              {gettext("工作区名称")}
            </label>
            <input
              id="rename-workspace-input"
              type="text"
              name="name"
              value={@rename_workspace.name}
              phx-mounted={JS.focus()}
              maxlength="80"
              autocomplete="off"
              class="w-full bg-main border rounded px-2 py-1.5 text-xs text-primary focus:outline-none focus:border-accent"
            />
          </div>
          <div
            :if={@rename_workspace.error}
            id="rename-workspace-error"
            class="text-xs text-error bg-error-subtle rounded px-3 py-2"
          >
            {@rename_workspace.error}
          </div>
        </div>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel_rename_workspace"
            class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
          >
            {gettext("取消")}
          </button>
          <button
            type="submit"
            id="rename-workspace-submit"
            class="text-xs bg-user text-white rounded px-4 py-1.5 transition-colors hover:bg-user-hover"
          >
            {gettext("保存")}
          </button>
        </div>
      </form>
    </div>

    <div
      :if={@remove_workspace}
      id="remove-workspace-overlay"
      class="absolute inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="cancel_remove_workspace"
      phx-key="Escape"
    >
      <button
        type="button"
        class="absolute inset-0 bg-transparent border-0"
        phx-click="cancel_remove_workspace"
        aria-label={gettext("取消")}
      ></button>
      <div
        id="remove-workspace-dialog"
        class="relative add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5"
      >
        <h3 class="text-base font-semibold text-primary mb-2">{gettext("移除工作区")}</h3>
        <p class="text-xs text-secondary mb-4">
          {gettext("移除「%{name}」后，其中的对话会进入已存档。项目目录不会被删除。",
            name: @remove_workspace.name
          )}
        </p>
        <div class="flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel_remove_workspace"
            class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
          >
            {gettext("取消")}
          </button>
          <button
            type="button"
            id="confirm-remove-workspace"
            phx-click="confirm_remove_workspace"
            class="text-xs bg-error text-white rounded px-4 py-1.5 transition-colors"
          >
            {gettext("移除")}
          </button>
        </div>
      </div>
    </div>

    <!-- Add Project Dialog (overlay) -->
    <div
      :if={@show_add_project}
      id="add-project-overlay"
      class="absolute inset-0 z-50 flex items-center justify-center pointer-events-none"
    >
      <div class="pointer-events-auto add-project-dialog bg-surface border rounded-xl shadow-2xl w-[420px] p-5">
        <h3 class="text-base font-semibold text-primary mb-4">{gettext("添加项目")}</h3>

        <div class="space-y-3 mb-4">
          <div>
            <label class="text-xs text-secondary block mb-1">{gettext("项目路径")}</label>
            <div class="flex gap-2">
              <input
                type="text"
                name="add_path"
                value={@add_project_form["path"]}
                phx-keyup="update_add_path"
                phx-value-value={@add_project_form["path"]}
                placeholder={
                  if(@sandbox_workspace?,
                    do: gettext("使用系统选择器导入到应用内"),
                    else: "/path/to/project"
                  )
                }
                readonly={@sandbox_workspace?}
                class="flex-1 bg-main border rounded px-2 py-1.5 text-xs text-primary font-mono focus:outline-none focus:border-accent"
              />
              <button
                type="button"
                phx-click="browse_folder"
                class="text-xs bg-transparent border rounded px-3 py-1.5 text-secondary transition-colors hover:text-primary hover:border-hover whitespace-nowrap"
              >
                {if @sandbox_workspace?, do: gettext("从下载导入…"), else: gettext("浏览...")}
              </button>
            </div>
            <p :if={@sandbox_workspace?} class="text-xs text-tertiary mt-2">
              {gettext(
                "手机不能直接把系统下载目录当工作区。系统授权后会把所选文件夹复制进应用私有目录。Downloads 根目录在部分 Android 版本上不可选，请选其中的项目子文件夹。"
              )}
            </p>
          </div>
          <div>
            <label class="text-xs text-secondary block mb-1">{gettext("项目名称 (可选)")}</label>
            <input
              type="text"
              name="add_name"
              value={@add_project_form["name"]}
              phx-keyup="update_add_name"
              phx-value-value={@add_project_form["name"]}
              placeholder={Path.basename(@add_project_form["path"]) || gettext("自动填充")}
              class="w-full bg-main border rounded px-2 py-1.5 text-xs text-primary focus:outline-none focus:border-accent"
            />
          </div>
          <div class="flex items-center justify-between gap-4 py-1">
            <div>
              <label for="add-project-builtin-memory" class="text-xs text-primary block">
                {gettext("使用自带的记忆功能")}
              </label>
              <p id="add-project-builtin-memory-desc" class="text-[11px] text-tertiary mt-0.5">
                {gettext("关闭后可使用配置的外部记忆工具")}
              </p>
            </div>
            <label class="relative inline-flex items-center cursor-pointer h-4 shrink-0">
              <input
                id="add-project-builtin-memory"
                type="checkbox"
                checked={@add_project_form["builtin_memory_enabled"]}
                phx-click="toggle_add_project_memory"
                aria-describedby="add-project-builtin-memory-desc"
                class="sr-only peer"
              />
              <span class="settings-toggle-track">
                <span class="settings-toggle-thumb"></span>
              </span>
            </label>
          </div>
          <div
            :if={@add_project_form["error"]}
            class="text-xs text-error bg-error-subtle rounded px-3 py-2"
          >
            {@add_project_form["error"]}
          </div>
        </div>

        <div class="flex justify-end gap-3">
          <button
            phx-click="cancel_add_project"
            class="text-xs text-secondary border rounded px-3 py-1.5 transition-colors hover:text-primary hover:border-hover"
          >
            {gettext("取消")}
          </button>
          <button
            phx-click="confirm_add_project"
            class="text-xs bg-user text-white rounded px-4 py-1.5 transition-colors hover:bg-user-hover"
          >
            {gettext("添加项目")}
          </button>
        </div>
      </div>
    </div>

    <!-- File Browser (LiveComponent) -->
    <.live_component
      module={HandbeanWeb.FileBrowserComponent}
      id="file-browser"
      show_browser={@show_file_browser}
      current_path={@file_browser_path}
    />
    """
  end
end
