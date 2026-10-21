defmodule Handbean.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "test endpoint ignores inherited desktop server and port settings" do
    endpoint = Application.fetch_env!(:handbean, HandbeanWeb.Endpoint)
    refute Keyword.fetch!(endpoint, :server)
    assert endpoint[:http][:port] == 4002

    keys =
      ~w(PHX_SERVER PORT HANDBEAN_COMPUTER_PORT HANDBEAN_COMPUTER_TOKEN HANDBEAN_NOTIFY_PORT HANDBEAN_NOTIFY_TOKEN HANDBEAN_FILE_MANAGER)

    originals = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env("PHX_SERVER", "true")
    System.put_env("PORT", "60302")
    System.put_env("HANDBEAN_COMPUTER_PORT", "60303")
    System.put_env("HANDBEAN_COMPUTER_TOKEN", "computer-secret")
    System.put_env("HANDBEAN_NOTIFY_PORT", "60304")
    System.put_env("HANDBEAN_NOTIFY_TOKEN", "notify-secret")
    System.put_env("HANDBEAN_FILE_MANAGER", "macos")

    try do
      config = Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :test)
      handbean = Keyword.fetch!(config, :handbean)

      refute Keyword.has_key?(handbean, HandbeanWeb.Endpoint)
      refute Keyword.has_key?(handbean, :computer_use_port)
      refute Keyword.has_key?(handbean, :computer_use_token)
      refute Keyword.has_key?(handbean, :macos_notify_port)
      refute Keyword.has_key?(handbean, :macos_notify_token)
      host = Keyword.get(handbean, :host, %{})
      refute Map.has_key?(host, :computer_use_backend)
      refute Map.has_key?(host, :file_manager_backend)
    after
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  @tag :darwin_process
  test "desktop host capabilities coexist and preserve the configured data directory" do
    keys =
      ~w(HANDBEAN_COMPUTER_PORT HANDBEAN_COMPUTER_TOKEN HANDBEAN_NOTIFY_PORT HANDBEAN_FILE_MANAGER HANDBEAN_DATA_DIR HANDBEAN_PUBLIC_BIND HANDBEAN_ACCESS_MODE DATABASE_PATH SECRET_KEY_BASE)

    originals = Map.new(keys, &{&1, System.get_env(&1)})
    original_host = Application.fetch_env(:handbean, :host)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case original_host do
        {:ok, host} -> Application.put_env(:handbean, :host, host)
        :error -> Application.delete_env(:handbean, :host)
      end
    end)

    Enum.each(keys, &System.delete_env/1)
    inherited_host = %{data_dir: "/inherited-data", platform: :desktop}
    Application.put_env(:handbean, :host, inherited_host)

    System.put_env(%{
      "HANDBEAN_COMPUTER_TOKEN" => "computer-secret",
      "HANDBEAN_ACCESS_MODE" => "local",
      "DATABASE_PATH" => Path.join(System.tmp_dir!(), "unused-runtime-config-test.db"),
      "SECRET_KEY_BASE" => String.duplicate("runtime-config-fixture", 3)
    })

    for env <- [:dev, :prod], data_dir <- [nil, "/desktop-data"] do
      if data_dir,
        do: System.put_env("HANDBEAN_DATA_DIR", data_dir),
        else: System.delete_env("HANDBEAN_DATA_DIR")

      System.put_env("HANDBEAN_COMPUTER_PORT", "60303")
      System.put_env("HANDBEAN_FILE_MANAGER", "macos")
      config = Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: env)

      assert config[:handbean][:host] == %{
               data_dir: data_dir || inherited_host.data_dir,
               platform: :desktop,
               computer_use_backend: Handbean.ComputerUse.Native,
               file_manager_backend: Handbean.Platform.FileManager.MacOS
             }

      System.delete_env("HANDBEAN_COMPUTER_PORT")
      config = Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: env)

      assert config[:handbean][:host] ==
               Map.put(inherited_host, :file_manager_backend, Handbean.Platform.FileManager.MacOS)
    end
  end

  test "production LAN HTTP is opt-in and cannot bypass password authentication" do
    keys =
      ~w(HANDBEAN_PUBLIC_BIND HANDBEAN_ALLOW_HTTP HANDBEAN_ACCESS_MODE HANDBEAN_ACCESS_PASSWORD HANDBEAN_FILE_MANAGER HANDBEAN_COMPUTER_PORT HANDBEAN_NOTIFY_PORT PHX_HOST PORT DATABASE_PATH SECRET_KEY_BASE)

    originals = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(keys, &System.delete_env/1)

    System.put_env(%{
      "HANDBEAN_PUBLIC_BIND" => "1",
      "HANDBEAN_ACCESS_PASSWORD" => "runtime-config-test-secret",
      "PHX_HOST" => "192.0.2.10",
      "PORT" => "51234",
      "DATABASE_PATH" => Path.join(System.tmp_dir!(), "unused-runtime-config-test.db"),
      "SECRET_KEY_BASE" => String.duplicate("runtime-config-fixture", 3)
    })

    read = fn ->
      Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :prod)
    end

    config = read.()
    refute config[:handbean][HandbeanWeb.Endpoint][:allow_http]
    assert config[:handbean][HandbeanWeb.Endpoint][:url][:scheme] == "https"
    assert config[:handbean][HandbeanWeb.Endpoint][:url][:port] == 443

    System.put_env("HANDBEAN_ALLOW_HTTP", "1")
    config = read.()
    endpoint = config[:handbean][HandbeanWeb.Endpoint]
    assert endpoint[:allow_http]
    assert endpoint[:url] == [host: "192.0.2.10", port: 51234, scheme: "http"]
    assert endpoint[:http][:ip] == {0, 0, 0, 0}
    assert config[:handbean][:access][:mode] == :password

    System.delete_env("HANDBEAN_ACCESS_PASSWORD")
    assert_raise RuntimeError, ~r/HANDBEAN_ACCESS_PASSWORD is required/, read

    System.put_env("HANDBEAN_ACCESS_MODE", "local")
    assert_raise RuntimeError, ~r/Refusing a non-loopback bind/, read
  end
end
