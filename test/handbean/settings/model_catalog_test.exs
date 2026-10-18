defmodule Handbean.Settings.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Handbean.Settings.ModelCatalog

  test "key_status never exposes the key" do
    assert ModelCatalog.key_status(nil) == :missing
    assert ModelCatalog.key_status(%{}) == :missing
    assert ModelCatalog.key_status(%{"apiKey" => ""}) == :missing
    assert ModelCatalog.key_status(%{"apiKey" => "sk-fixture"}) == :configured
    assert ModelCatalog.key_status(%{"apiKey" => "env:MY_KEY"}) == {:env, "MY_KEY"}
  end

  test "effective_max_tokens prefers the provider override" do
    assert ModelCatalog.effective_max_tokens(%{"maxTokens" => 2}, %{"maxTokens" => 1}) ==
             %{value: 2, source: :provider}

    assert ModelCatalog.effective_max_tokens(%{}, %{"maxTokens" => 1}) ==
             %{value: 1, source: :model}

    assert ModelCatalog.effective_max_tokens(%{"maxTokens" => "2"}, nil) ==
             %{value: nil, source: :unset}
  end
end
