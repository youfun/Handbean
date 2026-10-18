defmodule HandbeanProbe.BrowserHostTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.BrowserHost

  test "formats a snapshot payload" do
    body =
      BrowserHost.format_reply(%{
        "action" => "snapshot",
        "url" => "https://example.com/",
        "title" => "Example",
        "text" => "hello",
        "items" => [%{"ref" => "0", "tag" => "a", "text" => "More"}]
      })

    assert body =~ "url: https://example.com/"
    assert body =~ "title: Example"
    assert body =~ "[0] a More"
  end

  test "click and fill quote numeric refs in the selector" do
    click = BrowserHost.click_js("0")
    fill = BrowserHost.fill_js("0", "hi")
    assert click =~ ~s|document.querySelector("[data-handbean-ref=\\"0\\"]")|
    assert fill =~ ~s|document.querySelector("[data-handbean-ref=\\"0\\"]")|
    refute click =~ "data-handbean-ref=' + "
    refute fill =~ "data-handbean-ref=' + "
  end
end
