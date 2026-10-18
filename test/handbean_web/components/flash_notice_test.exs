defmodule HandbeanWeb.FlashNoticeTest do
  use HandbeanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "a reply notice is clickable and uses the app palette" do
    html =
      render_component(&HandbeanWeb.Layouts.flash_group/1, %{
        flash: %{
          "info" => %{
            body: "Agent 已在「Codex订阅模型非最新」中回复。",
            navigate: "/w/default/c/conv-reply-notice",
            navigate_with: :patch
          }
        }
      })

    assert html =~ "Agent 已在「Codex订阅模型非最新」中回复。"
    assert html =~ ~s(id="flash-info")
    assert html =~ ~s(href="/w/default/c/conv-reply-notice")
    assert html =~ ~s(phx-click="[[&quot;patch&quot;)
    assert html =~ "flash-notice-open"
    refute html =~ "alert-info"
    assert html =~ ~s(aria-label="close")
  end

  test "a settings-page reply notice navigates back to the conversation" do
    html =
      render_component(&HandbeanWeb.Layouts.flash_group/1, %{
        flash: %{
          "info" => %{
            body: "Agent replied.",
            navigate: "/w/default/c/conv-from-settings",
            navigate_with: :navigate
          }
        }
      })

    assert html =~ ~s(href="/w/default/c/conv-from-settings")
    assert html =~ ~s(phx-click="[[&quot;navigate&quot;)
    assert html =~ ~s(aria-label="close")
    refute html =~ ~s([[&quot;patch&quot;)
  end

  test "a plain notice stays non-navigating" do
    html =
      render_component(&HandbeanWeb.Layouts.flash_group/1, %{
        flash: %{"info" => "saved"}
      })

    assert html =~ "saved"
    assert html =~ "flash-notice-close"
    refute html =~ "flash-notice-open"
    refute html =~ "alert-info"
  end
end
