defmodule HandbeanWeb.WorkspaceLive.SidebarConversationComponents do
  @moduledoc false

  use HandbeanWeb, :html

  attr :id, :string, required: true
  attr :state, :atom, default: nil

  def run_indicator(assigns) do
    ~H"""
    <span
      class="conversation-run-indicator"
      data-run-id={@id}
      data-run-state={@state || :idle}
      role={@state && "img"}
      aria-label={
        case @state do
          :running ->
            gettext("运行中")

          :waiting_confirmation ->
            gettext("等待确认")

          _ ->
            nil
        end
      }
    >
      <svg
        class="conversation-idle-stem"
        viewBox="0 0 24 26"
        width="20"
        height="22"
        shape-rendering="crispEdges"
        aria-hidden="true"
      >
        <g transform="translate(0 7)">
          <path
            class="idle-stem-outline"
            d="M11 5h1v3h-1zM11 3h1v3h-1zM12 2h4v1h1v1h-1v1h-4V4h-1V3h1z"
          />
          <path class="idle-stem-fill" d="M12 3h4v1h-4z" />
          <path class="idle-stem-highlight" d="M13 2h2v1h-2z" />
        </g>
      </svg>
      <svg
        class="conversation-run-sprite"
        viewBox="0 0 24 26"
        width="20"
        height="22"
        shape-rendering="crispEdges"
        aria-hidden="true"
      >
        <path class="run-shadow" d="M6 24h12v1H6z" />
        <g class="run-character">
          <g class="run-outline">
            <path class="run-leg-left" d="M8 21h2v3H7v-1h1z" />
            <path class="run-leg-right" d="M15 21h2v2h1v1h-3z" />
          </g>
          <g class="run-upper">
            <g class="run-outline">
              <g class="run-arm-left">
                <path d="M4 16h1v4H4z" />
                <path class="run-fill" d="M3 19h2v2H3z" />
              </g>
              <g class="run-arm-right">
                <path d="M19 16h1v4h-1z" />
                <path class="run-fill" d="M19 19h2v2h-2z" />
              </g>
            </g>
            <g class="run-leaf">
              <path class="run-outline" d="M11 5h1v3h-1zM11 3h1v3h-1zM12 2h4v1h1v1h-1v1h-4V4h-1V3h1z" />
              <path class="run-fill" d="M12 3h4v1h-4z" />
              <path class="run-highlight" d="M13 2h2v1h-2z" />
            </g>
            <path class="run-outline" d="M9 8h6v1h2v1h1v1h1v10h-1v1h-1v1H7v-1H6v-1H5V11h1v-1h1V9h2z" />
            <path class="run-fill" d="M9 9h6v1h2v1h1v10h-1v1H7v-1H6V11h1v-1h2z" />
            <path class="run-highlight" d="M9 9h6v1h-1v1h-2v1H8v1H7v-2h1v-1h1z" />
            <path class="run-shade" d="M17 17h1v4h-1v1H7v-1h8v-1h1v-1h1z" />
            <path class="run-eyes" fill="#263b25" d="M8 14h2v2H8zM14 14h2v2h-2z" />
            <path fill="#db9968" d="M7 17h1v1H7zM16 17h1v1h-1z" />
          </g>
        </g>
      </svg>
    </span>
    """
  end

  attr :conv, :map, required: true
  attr :conversation_menu_id, :any, required: true

  attr :id_prefix, :string, default: ""

  def conversation_menu(assigns) do
    ~H"""
    <div class="conversation-menu">
      <button
        type="button"
        phx-click="toggle_conversation_menu"
        phx-value-id={@conv.id}
        data-conversation-menu-toggle
        id={"conversation-menu-#{@id_prefix}#{menu_scope_id(@conv)}-#{@conv.id}"}
        class={[
          "conversation-action",
          @conversation_menu_id == @conv.id && "is-open"
        ]}
        title={gettext("更多操作")}
        aria-label={gettext("更多操作")}
        aria-haspopup="menu"
        aria-expanded={to_string(@conversation_menu_id == @conv.id)}
      >
        <span class="sr-only">{gettext("更多操作")}</span>
        <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor" aria-hidden="true">
          <circle cx="2.25" cy="6" r="1" />
          <circle cx="6" cy="6" r="1" />
          <circle cx="9.75" cy="6" r="1" />
        </svg>
      </button>
      <div
        :if={@conversation_menu_id == @conv.id}
        id={"conversation-menu-panel-#{@id_prefix}#{@conv.id}"}
        class="conversation-menu-panel"
        role="menu"
        phx-click-away="close_conversation_menu"
      >
        <button
          type="button"
          role="menuitem"
          phx-click="toggle_pin_conversation"
          phx-value-id={@conv.id}
          phx-value-ws_id={@conv.workspace_id}
          id={"conversation-action-pin-#{@id_prefix}#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path
              d="M4.1 1.4h3.8v1.7l1.2 1.2H2.9l1.2-1.2V1.4Z"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linejoin="round"
            />
            <path d="M6 4.3v6.3" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" />
          </svg>
          <span>{if(@conv.pinned, do: gettext("取消置顶"), else: gettext("置顶"))}</span>
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="open_rename_conversation"
          phx-value-id={@conv.id}
          phx-value-ws_id={@conv.workspace_id}
          id={"conversation-action-rename-#{@id_prefix}#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path
              d="M7.2 2.1 9.9 4.8 4.4 10.3 1.5 10.5l.2-2.9L7.2 2.1Z"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linejoin="round"
            />
            <path
              d="M6.4 2.9 9.1 5.6"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linecap="round"
            />
          </svg>
          <span>{gettext("重命名")}</span>
        </button>
        <button
          type="button"
          role="menuitem"
          id={"conversation-action-copy-id-#{@id_prefix}#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item"
          phx-hook="CopyText"
          data-copy={@conv.id}
          title={gettext("复制对话 ID，用于对话协作")}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <rect
              x="4.25"
              y="3.25"
              width="5.5"
              height="6.5"
              rx="0.75"
              stroke="currentColor"
              stroke-width="1.1"
            />
            <path
              d="M3.25 8.75H2.75A.75.75 0 0 1 2 8V2.75A.75.75 0 0 1 2.75 2H8a.75.75 0 0 1 .75.75V3.25"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linecap="round"
            />
          </svg>
          <span class="copy-idle">{gettext("复制 ID")}</span>
          <span class="copy-done">{gettext("已复制")}</span>
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="archive_conversation"
          phx-value-id={@conv.id}
          phx-value-ws_id={@conv.workspace_id}
          id={"conversation-action-archive-#{@id_prefix}#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path
              d="M2 3.5h8M4.5 3.5V2.75a.75.75 0 0 1 .75-.75h1.5a.75.75 0 0 1 .75.75V3.5M3 3.5l.5 6.75a.75.75 0 0 0 .75.75h3.5a.75.75 0 0 0 .75-.75L9 3.5"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
          <span>{gettext("归档")}</span>
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="open_delete_conversation"
          phx-value-id={@conv.id}
          phx-value-ws_id={@conv.workspace_id}
          id={"conversation-action-delete-#{@id_prefix}#{menu_scope_id(@conv)}-#{@conv.id}"}
          class="conversation-menu-item danger"
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path
              d="M2 3.5h8M4.5 3.5V2.75a.75.75 0 0 1 .75-.75h1.5a.75.75 0 0 1 .75.75V3.5M3 3.5l.5 6.75a.75.75 0 0 0 .75.75h3.5a.75.75 0 0 0 .75-.75L9 3.5"
              stroke="currentColor"
              stroke-width="1.1"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
          <span>{gettext("删除对话")}</span>
        </button>
      </div>
    </div>
    """
  end

  defp menu_scope_id(%{scope: "free"}), do: "free"
  defp menu_scope_id(%{workspace_id: id}) when is_binary(id) and id != "", do: id
  defp menu_scope_id(_), do: "free"
end
