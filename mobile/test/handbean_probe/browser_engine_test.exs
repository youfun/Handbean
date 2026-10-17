defmodule HandbeanProbe.BrowserEngineTest do
  use ExUnit.Case, async: false

  alias HandbeanProbe.Browser.{Engine, Nif}

  test "host uses the safe Erlang stub instead of the Android NIF" do
    assert {:error, :nif_not_loaded} = Nif.command(%{op: :eval, session_id: "x"})
  end

  test "ensure_loaded loads the Erlang stub on host" do
    :code.purge(:handbean_browser)
    :code.delete(:handbean_browser)
    assert :ok = Nif.ensure_loaded()
    assert function_exported?(:handbean_browser, :command, 1)
  end

  test "the NIF adapter loads its Erlang module before checking the command export" do
    :code.purge(:handbean_browser)
    :code.delete(:handbean_browser)
    refute function_exported?(:handbean_browser, :command, 1)

    assert {:error, :nif_not_loaded} = Nif.command(%{op: :eval, session_id: "x"})
    assert function_exported?(:handbean_browser, :command, 1)
  end

  test "wire_map keeps atom keys and maps only schema string keys" do
    mapped =
      Nif.wire_map(%{
        :op => :eval,
        "session_id" => "s1",
        "generation" => 3,
        "overlay" => true,
        "caller" => self()
      })

    assert mapped == %{
             op: "eval",
             session_id: "s1",
             generation: 3,
             overlay: "true",
             caller: self()
           }

    assert :overlay in Nif.wire_keys()
  end

  test "wire_map drops unknown string keys instead of minting atoms" do
    unknown = "nif_unknown_key_#{System.unique_integer([:positive])}"

    assert Nif.wire_map(%{"op" => "load", unknown => "x", 42 => "y"}) == %{op: "load"}

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "fake engine is used when installed" do
    Application.put_env(:handbean_probe, :browser_engine_fake, fn cmd, _opts ->
      {:ok, %{echo: cmd.op}}
    end)

    on_exit(fn -> Application.delete_env(:handbean_probe, :browser_engine_fake) end)

    assert {:ok, %{echo: :load}} = Engine.command(%{op: :load, url: "https://example.com"})
  end

  test "install uses the session engine without registering the lossy legacy runner" do
    previous_engine = Application.get_env(:handbean, :browser_engine)
    previous_webview = Application.get_env(:handbean, :browser_webview)

    on_exit(fn ->
      restore(:browser_engine, previous_engine)
      restore(:browser_webview, previous_webview)
    end)

    Application.put_env(:handbean, :browser_webview, fn _command, _opts -> {:ok, "legacy"} end)
    assert :ok = Engine.install!()
    assert is_function(Application.get_env(:handbean, :browser_engine), 2)
    refute Application.get_env(:handbean, :browser_webview)
  end

  test "native HomeScreen does not own browser or preview WebViews" do
    # The screen plus its domain modules (home_screen/*.ex).
    source =
      [Path.expand("../../lib/handbean_probe/home_screen.ex", __DIR__)]
      |> Enum.concat(
        Path.wildcard(Path.expand("../../lib/handbean_probe/home_screen/*.ex", __DIR__))
      )
      |> Enum.map_join("\n", &File.read!/1)

    refute source =~ "Mob.UI.webview"
    refute source =~ "node(:web_view"
    refute source =~ "WebViewSession.start_link"
    assert source =~ "NativeChat.open_tool_action"
  end

  defp restore(key, nil), do: Application.delete_env(:handbean, key)
  defp restore(key, value), do: Application.put_env(:handbean, key, value)
end
