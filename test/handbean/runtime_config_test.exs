defmodule Handbean.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "test endpoint ignores inherited desktop server and port settings" do
    endpoint = Application.fetch_env!(:handbean, HandbeanWeb.Endpoint)
    refute Keyword.fetch!(endpoint, :server)
    assert endpoint[:http][:port] == 4002

    keys =
      ~w(PHX_SERVER PORT HANDBEAN_COMPUTER_PORT HANDBEAN_COMPUTER_TOKEN HANDBEAN_NOTIFY_PORT HANDBEAN_NOTIFY_TOKEN)

    originals = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env("PHX_SERVER", "true")
    System.put_env("PORT", "60302")
    System.put_env("HANDBEAN_COMPUTER_PORT", "60303")
    System.put_env("HANDBEAN_COMPUTER_TOKEN", "computer-secret")
    System.put_env("HANDBEAN_NOTIFY_PORT", "60304")
    System.put_env("HANDBEAN_NOTIFY_TOKEN", "notify-secret")

    try do
      config = Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :test)
      handbean = Keyword.fetch!(config, :handbean)

      refute Keyword.has_key?(handbean, HandbeanWeb.Endpoint)
      refute Keyword.has_key?(handbean, :computer_use_port)
      refute Keyword.has_key?(handbean, :computer_use_token)
      refute Keyword.has_key?(handbean, :macos_notify_port)
      refute Keyword.has_key?(handbean, :macos_notify_token)
    after
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
