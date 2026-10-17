defmodule Handbean.MCP.SettingsTest do
  use ExUnit.Case, async: false
  alias Handbean.MCP.{Access, ConfigLoader, Settings}

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-settings-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    opts = [user_config_path: Path.join(root, "mcp.json")]
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: opts}
  end

  test "atomic catalog writes preserve other servers and never return stored credentials", %{
    opts: opts
  } do
    form =
      Settings.new_form("workspace-a")
      |> Map.merge(%{
        "name" => "Private docs",
        "url" => "https://docs.example/mcp",
        "auth" => "bearer",
        "token" => "secret-one"
      })

    assert {:ok, id} = Settings.save(form, opts)

    assert {:ok, second} =
             Settings.save(%{form | "name" => "Other", "token" => "secret-two"}, opts)

    assert {:ok, edit} = Settings.edit(id, opts)
    assert edit["has_credentials"]
    assert edit["token"] == ""
    assert {:ok, ^id} = Settings.save(%{edit | "name" => "Renamed"}, opts)
    assert {:ok, raw} = Settings.read(opts)
    assert raw["mcpServers"][id]["headers"] == %{"authorization" => "Bearer secret-one"}
    assert raw["mcpServers"][second]["headers"] == %{"authorization" => "Bearer secret-two"}
    assert {:ok, entries} = Settings.list(opts)
    refute inspect(entries) =~ "secret-one"
    assert Bitwise.band(File.stat!(Settings.path(opts)).mode, 0o777) == 0o600
    assert {:ok, ^id} = Settings.save(%{edit | "auth" => "none"}, opts)
    assert {:ok, cleared} = Settings.edit(id, opts)
    refute cleared["has_credentials"]
    assert :ok = Settings.delete(id, opts)
    assert {:ok, [%{id: ^second}]} = Settings.list(opts)
    assert {:error, _} = Settings.save(edit, opts)
  end

  test "deny-by-default selected access cannot be bypassed by project override", %{
    opts: opts,
    root: root
  } do
    form =
      Settings.new_form("a")
      |> Map.merge(%{"name" => "Docs", "url" => "https://docs.example/mcp"})

    {:ok, id} = Settings.save(form, opts)

    File.write!(
      Path.join(root, ".mcp.json"),
      Jason.encode!(%{"mcpServers" => %{id => %{"url" => "https://override.example/mcp"}}})
    )

    allowed = Keyword.merge(opts, project: root, workspace_id: "a")
    denied = Keyword.put(allowed, :workspace_id, "b")
    assert Map.has_key?(Access.config(allowed).servers, id)
    assert Access.config(denied).servers == %{}
    assert Access.config(Keyword.delete(allowed, :workspace_id)).servers == %{}
    {:ok, edit} = Settings.edit(id, opts)
    {:ok, ^id} = Settings.save(%{edit | "disabled" => true}, opts)
    assert Access.config(allowed).servers == %{}
  end

  test "malformed catalog fails closed and editing does not overwrite it", %{opts: opts} do
    File.write!(Settings.path(opts), "broken-json")

    form =
      Settings.new_form("a")
      |> Map.merge(%{"name" => "Docs", "url" => "https://docs.example/mcp"})

    assert {:error, _} = Settings.save(form, opts)
    assert File.read!(Settings.path(opts)) == "broken-json"
    assert Access.config(opts).servers == %{}
  end

  test "invalid auth/URL is rejected while zero workspaces is valid denial", %{opts: opts} do
    form = Settings.new_form(nil) |> Map.merge(%{"name" => "Docs", "url" => "file:///tmp/mcp"})
    assert {:error, _} = Settings.save(form, opts)

    form = %{
      form
      | "url" => "https://docs.example/mcp",
        "auth" => "headers",
        "headers_json" => ~s({"X-Key":42})
    }

    assert {:error, _} = Settings.save(form, opts)
    form = %{form | "headers_json" => ~s({"X-Key":"secret"})}
    assert {:ok, _} = Settings.save(form, opts)
    assert {:ok, %{servers: servers}} = ConfigLoader.load(opts)
    assert servers == %{}
  end

  test "blank credentials survive path changes but cannot follow an origin change", %{opts: opts} do
    form =
      Settings.new_form("a")
      |> Map.merge(%{
        "name" => "Docs",
        "url" => "https://docs.example/mcp",
        "auth" => "bearer",
        "token" => "original-secret"
      })

    assert {:ok, id} = Settings.save(form, opts)
    assert {:ok, edit} = Settings.edit(id, opts)
    assert {:ok, ^id} = Settings.save(%{edit | "url" => "https://docs.example/new-path"}, opts)

    for url <- [
          "http://docs.example/mcp",
          "https://other.example/mcp",
          "https://docs.example:8443/mcp"
        ] do
      assert {:error, "Server origin changed." <> _} = Settings.save(%{edit | "url" => url}, opts)
    end

    assert {:ok, ^id} =
             Settings.save(
               %{edit | "url" => "https://other.example/mcp", "token" => "new-secret"},
               opts
             )

    assert {:ok, raw} = Settings.read(opts)
    assert raw["mcpServers"][id]["headers"] == %{"authorization" => "Bearer new-secret"}
  end

  test "concurrent additions are not lost", %{opts: opts} do
    1..8
    |> Task.async_stream(fn n ->
      form =
        Settings.new_form("a")
        |> Map.merge(%{"name" => "Server #{n}", "url" => "https://example.test/#{n}"})

      assert {:ok, _} = Settings.save(form, opts)
    end)
    |> Stream.run()

    assert {:ok, entries} = Settings.list(opts)
    assert length(entries) == 8
  end
end
