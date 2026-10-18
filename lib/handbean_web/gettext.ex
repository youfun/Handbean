defmodule HandbeanWeb.Gettext do
  @moduledoc """
  Gettext 模块 —— 为 HandbeanWeb 层提供多语言翻译。

  默认语言：zh_CN（简体中文），支持 en（英文）。

  用法：
    - HEEx 模板中：`<%= gettext("选择文件夹") %>`
    - 通过 handbean_web.ex 的 html_helpers 自动注入（use Gettext, backend: HandbeanWeb.Gettext）
    - 错误翻译：`Gettext.dgettext(HandbeanWeb.Gettext, "errors", msg, opts)`
  """
  use Gettext.Backend, otp_app: :handbean
end
