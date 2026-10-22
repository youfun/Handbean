defmodule HandbeanWeb.PWATest do
  use HandbeanWeb.ConnCase, async: true

  test "manifest publishes an installable standalone app with maskable artwork and screenshots",
       %{
         conn: conn
       } do
    body = conn |> get("/manifest.webmanifest") |> response(200)
    manifest = Handbean.JSON.decode!(body)

    assert manifest["display"] == "standalone"
    assert manifest["start_url"] == "/"
    assert manifest["scope"] == "/"
    assert Enum.any?(manifest["icons"], &(&1["purpose"] == "maskable"))

    assert MapSet.new(Enum.map(manifest["screenshots"], & &1["form_factor"])) ==
             MapSet.new(["wide", "narrow"])

    paths = Enum.map(manifest["icons"] ++ manifest["screenshots"], & &1["src"])

    for path <- paths do
      assert File.regular?(Path.join("priv/static", String.trim_leading(path, "/")))
    end
  end

  test "offline fallback is a generic retry page with no persisted application data", %{
    conn: conn
  } do
    body = conn |> get("/offline.html") |> response(200)

    assert body =~ "Handbean 暂时无法连接"
    assert body =~ "不保存或显示任何对话与工作区内容"
    assert body =~ ~s(href="/")
  end
end
