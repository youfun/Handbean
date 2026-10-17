defmodule HandbeanWeb.Feature.UILocaleFeatureTest do
  @moduledoc """
  Run: mix test --include e2e test/feature/ui_locale_feature_test.exs

  The language selected in Settings survives a fresh browser session with an
  English language header, overrides an old session, and can be changed back.
  """
  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.TestSupport.E2EHarness
  alias Handbean.Settings.UI

  @moduletag :e2e

  test "language selection persists in SQLite and restores in a fresh session", %{conn: conn} do
    E2EHarness.isolate_home!("ui-locale")
    {:ok, workspace} = Handbean.WorkspaceStore.ensure_default!()

    path =
      "/settings?" <>
        URI.encode_query(%{
          "tab" => "ui",
          "workspace_id" => workspace["id"],
          "conversation_id" => "locale-test"
        })

    conn
    |> Plug.Conn.put_req_header("accept-language", "en-US,en;q=0.9")
    |> visit(path)
    |> assert_has("#ui-locale-en.active")
    |> click_button("#ui-locale-zh_CN", "Chinese (Simplified)")
    |> assert_path("/settings",
      query_params: %{
        "tab" => "ui",
        "workspace_id" => workspace["id"],
        "conversation_id" => "locale-test"
      }
    )
    |> assert_has("#ui-locale-zh_CN.active")

    assert UI.locale() == "zh_CN"
    assert Handbean.Repo.get!(UI, "ui.locale").value == "zh_CN"

    fresh_conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, "localhost")
      |> HandbeanWeb.ConnCase.authenticate()
      |> Plug.Conn.put_req_header("accept-language", "en-US")

    fresh_conn
    |> visit(path)
    |> assert_has("#ui-locale-zh_CN.active")

    fresh_conn
    |> Plug.Test.init_test_session(%{"locale" => "en"})
    |> visit(path)
    |> assert_has("#ui-locale-zh_CN.active")
    |> click_button("#ui-locale-en", "English")
    |> assert_has("#ui-locale-en.active")

    assert UI.locale() == "en"

    fresh_conn
    |> Plug.Conn.put_req_header("accept-language", "zh-CN")
    |> visit(path)
    |> assert_has("#ui-locale-en.active")
  end
end
