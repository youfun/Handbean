defmodule Handbean.BrowserAnnotationTest do
  @moduledoc """
  Failure list for untrusted browser annotation payloads:

  - selector longer than 500 characters is truncated, and the rest is dropped
  - newlines and backticks in comments cannot break the markdown row
  - missing selector, tag, or rect drops that element
  - a non-http(s) URL, or a URL with whitespace, is `{:error, :invalid_url}`
  - a negative or non-numeric rect drops that element
  - a non-map payload is `{:error, :invalid_payload}`
  """

  use ExUnit.Case, async: true

  alias Handbean.BrowserAnnotation

  test "rejects non-http urls and non-maps" do
    assert BrowserAnnotation.from_untrusted("http://example.com") == {:error, :invalid_payload}

    assert BrowserAnnotation.from_untrusted(%{"url" => "file:///etc/hosts"}) ==
             {:error, :invalid_url}

    assert BrowserAnnotation.from_untrusted(%{"url" => "javascript:alert(1)"}) ==
             {:error, :invalid_url}

    assert BrowserAnnotation.from_untrusted(%{"url" => "http://example.com/\n"}) ==
             {:error, :invalid_url}
  end

  test "drops broken elements and reindexes the rest" do
    long_selector = String.duplicate("a", 800)

    assert {:ok, payload} =
             BrowserAnnotation.from_untrusted(%{
               "url" => "http://127.0.0.1:4000/",
               "elements" => [
                 %{
                   "selector" => "#bad",
                   "tag" => "div",
                   "rect" => %{"x" => -1, "y" => 0, "width" => 1, "height" => 1}
                 },
                 %{"selector" => "main", "tag" => "main", "rect" => %{"x" => "nope"}},
                 %{
                   "index" => 9,
                   "selector" => long_selector,
                   "tag" => "button\n",
                   "text" => "Click\nme",
                   "comment" => "fix `this`\nplease",
                   "rect" => %{"x" => 1, "y" => 2, "width" => 3, "height" => 4},
                   "source" => %{"file" => "lib/app.ex", "line" => 12, "column" => 2}
                 }
               ]
             })

    assert [%{index: 1, selector: selector, tag: "button", text: "Click me"}] = payload.elements
    assert selector == String.duplicate("a", 500)

    prompt = BrowserAnnotation.format_prompt(%{payload | screenshot: false})
    assert prompt =~ "(button) — fix 'this' please"
    refute prompt =~ "\nplease"
    refute prompt =~ "this`"
    assert prompt =~ "rect: 3×4 at (1, 2)"
    assert prompt =~ ~s(text: "Click me")
    assert prompt =~ "source: `lib/app.ex:12:2`"
    assert prompt =~ "no screenshot could be taken"

    with_shot = BrowserAnnotation.format_prompt(%{payload | screenshot: true})
    refute with_shot =~ "rect:"
    assert with_shot =~ "attached screenshot"
  end

  test "keeps a mark that has no comment" do
    assert {:ok, payload} =
             BrowserAnnotation.from_untrusted(%{
               "url" => "https://example.com",
               "elements" => [
                 %{
                   "selector" => "main",
                   "tag" => "main",
                   "rect" => %{"x" => 0, "y" => 0, "width" => 10, "height" => 10}
                 }
               ]
             })

    assert BrowserAnnotation.format_prompt(payload) =~ "#1 `main` (main) — (no comment)"
  end
end
