defmodule HandbeanWeb.Components.PushNotifications do
  @moduledoc "Browser-owned Web Push consent controls for the UI settings page."

  use HandbeanWeb, :html

  attr(:locale, :string, required: true)

  def render(assigns) do
    ~H"""
    <section
      id="push-notifications"
      class="settings-form-section"
      phx-hook=".Notifications"
      data-locale={@locale}
      aria-labelledby="push-notifications-title"
      aria-busy="true"
    >
      <div class="settings-section-heading">
        <div id="push-notifications-title" class="settings-section-title">
          {gettext("推送通知")}
        </div>
        <div class="settings-help-text">
          {gettext("在此浏览器接收任务完成和需要处理的提醒。每台设备需单独开启。")}
          {gettext("通知尽力送达，服务器离线或重启期间可能错过提醒。")}
        </div>
      </div>
      <div class="settings-card">
        <div class="settings-field-row">
          <div class="settings-field-copy">
            <div class="settings-field-title">{gettext("此浏览器的通知")}</div>
            <p class="settings-field-desc" data-push-status role="status" aria-live="polite">
              {gettext("正在检查通知支持…")}
            </p>
            <p class="settings-field-desc" data-push-error role="alert" hidden>
              {gettext("操作未完成，请检查网络与浏览器通知设置后重试。")}
            </p>
          </div>
          <div class="settings-field-control flex flex-wrap gap-2">
            <button type="button" class="settings-btn" data-push-action="enable" disabled>
              {gettext("开启通知")}
            </button>
            <button type="button" class="settings-btn" data-push-action="disable" hidden>
              {gettext("关闭通知")}
            </button>
            <button type="button" class="settings-btn" data-push-action="test" hidden>
              {gettext("发送测试通知")}
            </button>
            <button type="button" class="settings-btn" data-push-action="reconcile" hidden>
              {gettext("重试")}
            </button>
          </div>
        </div>
      </div>
      <div hidden aria-hidden="true">
        <span data-push-message="checking">{gettext("正在检查通知支持…")}</span>
        <span data-push-message="cleanup">{gettext("关闭通知尚未完成，请重试以清理订阅。")}</span>
        <span data-push-message="failed">{gettext("操作未完成，请检查网络与浏览器通知设置后重试。")}</span>
        <span data-push-message="subscription_conflict">
          {gettext("此订阅属于之前的浏览器会话，请先关闭通知，再重新开启。")}
        </span>
        <span data-push-message="subscription_expired">
          {gettext("通知订阅已过期，请点击开启通知重新连接此浏览器。")}
        </span>
        <span data-push-message="subscription_limit">{gettext("通知订阅数量已达上限，请关闭其他设备的通知后重试。")}</span>
        <span data-push-message="rollback_failed">{gettext("订阅保存失败，浏览器订阅尚未清理，请点击关闭通知重试。")}</span>
        <span data-push-message="busy">{gettext("正在更新通知设置…")}</span>
        <span data-push-message="disabled">{gettext("通知已关闭。点击开启后，浏览器会请求通知权限。")}</span>
        <span data-push-message="enabled">{gettext("此浏览器已开启通知。")}</span>
        <span data-push-message="sent">{gettext("测试通知已发送，请检查系统通知。")}</span>
        <span data-push-message="denied">
          {gettext("通知权限已被拒绝，请在浏览器的站点设置中允许通知后刷新页面。")}
        </span>
        <span data-push-message="dismissed">{gettext("尚未授予通知权限，可以再次点击开启通知。")}</span>
        <span data-push-message="insecure">{gettext("推送通知需要 HTTPS 安全连接（本机 localhost 除外）。")}</span>
        <span data-push-message="unsupported">{gettext("此浏览器不支持推送通知，请使用支持 Web Push 的浏览器。")}</span>
        <span data-push-message="install">
          {gettext("在 iPhone 或 iPad 上，请在 Safari 中选择“分享”→“添加到主屏幕”，再从主屏幕打开 Handbean 开启通知。")}
        </span>
        <span data-push-message="unconfigured">
          {gettext("服务器尚未配置推送通知，请联系管理员配置 Web Push 联系地址。")}
        </span>
        <span data-push-message="renewal">{gettext("通知配置已更新，请点击开启通知重新连接此浏览器。")}</span>
      </div>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Notifications">
      import { webPush } from "@/js/web_push.js"
      import { renderPushNotifications } from "@/js/hooks/push_notifications.js"

      export default {
        mounted() {
          this.push = webPush()
          this.push.setLocale(this.el.dataset.locale)
          this.stopListening = this.push.subscribe((state) => this.renderPush(state))
          this.onPushClick = (event) => {
            const button = event.target.closest("[data-push-action]")
            if (!button || !this.el.contains(button) || button.disabled) return
            const action = button.dataset.pushAction
            if (["enable", "disable", "test", "reconcile"].includes(action)) {
              // Keep enable() in the click stack to preserve notification permission's user gesture.
              void this.push[action]()
            }
          }
          this.el.addEventListener("click", this.onPushClick)
          void this.push.reconcile()
        },

        updated() {
          const changed = this.el.dataset.locale !== this.pushLocale
          this.push.setLocale(this.el.dataset.locale)
          this.renderPush(this.push.state)
          if (changed) void this.push.reconcile()
        },

        renderPush(state) {
          this.pushLocale = this.el.dataset.locale
          renderPushNotifications(this.el, state)
        },

        destroyed() {
          this.stopListening?.()
          this.el.removeEventListener("click", this.onPushClick)
        }
      }
    </script>
    """
  end
end
