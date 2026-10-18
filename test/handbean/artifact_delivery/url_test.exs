defmodule Handbean.ArtifactDelivery.UrlTest do
  use ExUnit.Case, async: true

  alias Handbean.ArtifactDelivery.Url

  test "accepts absolute http and https hosts" do
    assert {:ok, "https://example.com/docs"} = Url.parse("https://example.com/docs")
    assert {:ok, "http://orders.example.org/a"} = Url.parse("http://orders.example.org/a")
  end

  test "rejects file javascript userinfo and relative urls" do
    assert {:error, :invalid_url} = Url.parse("file:///etc/passwd")
    assert {:error, :invalid_url} = Url.parse("javascript:alert(1)")
    assert {:error, :userinfo} = Url.parse("https://user:pass@example.com/")
    assert {:error, :invalid_url} = Url.parse("/relative")
    assert {:error, :empty} = Url.parse("  ")
  end
end
