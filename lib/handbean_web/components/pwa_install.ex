defmodule HandbeanWeb.Components.PWAInstall do
  @moduledoc "Browser-owned installation controls for the Handbean PWA."

  use HandbeanWeb, :html

  def render(assigns) do
    ~H"""
    <section
      id="pwa-install"
      class="settings-form-section"
      phx-hook="PWAInstall"
      aria-labelledby="pwa-install-title"
      aria-busy="false"
    >
      <div class="settings-section-heading">
        <div id="pwa-install-title" class="settings-section-title">{gettext("安装 Handbean")}</div>
        <div class="settings-help-text">
          {gettext("将 Handbean 安装为独立窗口。应用仍连接当前 Handbean 服务，不会离线保存对话或工作区文件。")}
        </div>
      </div>
      <div class="settings-card">
        <div class="settings-field-row">
          <div class="settings-field-copy">
            <div class="settings-field-title">{gettext("此设备上的应用")}</div>
            <p class="settings-field-desc" data-pwa-install-status role="status" aria-live="polite">
              {gettext("如果浏览器支持安装，可以从浏览器菜单安装 Handbean。")}
            </p>
            <div class="pwa-ios-guide" data-pwa-ios-guide hidden>
              <span>{gettext("在 Safari 中点击“分享”")}</span>
              <span aria-hidden="true">→</span>
              <span>{gettext("选择“添加到主屏幕”")}</span>
              <span aria-hidden="true">→</span>
              <span>{gettext("从主屏幕打开 Handbean")}</span>
            </div>
          </div>
          <div class="settings-field-control">
            <button
              type="button"
              class="settings-btn settings-btn-primary"
              data-pwa-install-action
              hidden
            >
              {gettext("安装 Handbean")}
            </button>
          </div>
        </div>
      </div>
      <div hidden aria-hidden="true">
        <span data-pwa-install-message="browser">
          {gettext("如果浏览器支持安装，可以从浏览器菜单安装 Handbean。")}
        </span>
        <span data-pwa-install-message="available">{gettext("Handbean 可以安装为独立窗口。")}</span>
        <span data-pwa-install-message="installing">{gettext("正在打开浏览器安装确认…")}</span>
        <span data-pwa-install-message="accepted">{gettext("浏览器正在完成安装…")}</span>
        <span data-pwa-install-message="installed">
          {gettext("Handbean 已安装。请从系统中的 Handbean 图标打开独立窗口。")}
        </span>
        <span data-pwa-install-message="standalone">{gettext("Handbean 正以独立窗口运行。")}</span>
        <span data-pwa-install-message="dismissed">
          {gettext("已取消安装。需要时可从浏览器菜单再次安装。")}
        </span>
        <span data-pwa-install-message="failed">
          {gettext("未能打开安装确认，请尝试使用浏览器菜单安装。")}
        </span>
        <span data-pwa-install-message="ios">
          {gettext("iPhone 和 iPad 需要通过 Safari 添加到主屏幕。")}
        </span>
      </div>
    </section>
    """
  end
end
