defmodule Handbean.PathsTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    :ok
  end

  test "priv_dir uses Application.app_dir off device" do
    Application.delete_env(:handbean, :host)
    assert Handbean.Paths.priv_dir() == Application.app_dir(:handbean, "priv")

    assert Handbean.Paths.static_root() ==
             Path.join(Application.app_dir(:handbean, "priv"), "static")
  end

  test "priv_dir uses Host.priv_dir when configured" do
    Handbean.Host.put!(%{priv_dir: "/tmp/mob-beams/priv"})
    assert Handbean.Paths.priv_dir() == "/tmp/mob-beams/priv"
    assert Handbean.Paths.migrations_dir() == "/tmp/mob-beams/priv/repo/migrations"
  end

  test "Home.expand maps ~/.handbean onto Host.data_dir" do
    Handbean.Host.put!(%{data_dir: "/tmp/mob-data"})

    assert Handbean.Home.expand("~/.handbean/models.json") ==
             "/tmp/mob-data/.handbean/models.json"
  end

  test "phone host tools drop bash and keep grep" do
    Handbean.Host.put!(%{
      data_dir: "/tmp/mob-data",
      priv_dir: "/tmp/mob-beams/priv",
      shell: false,
      terminal: false,
      browser_backend: :webview,
      artifact_delivery_backend: Handbean.ArtifactDelivery,
      host_script: true,
      beam_eval: false,
      mcp: false
    })

    names = Enum.map(Handbean.Agent.default_tools(), & &1.name())
    refute "bash" in names
    assert "browser" in names
    assert "preview_serve" in names
    assert "open_url" in names
    assert "open_file" in names
    assert "share_file" in names
    assert "run_elixir_script" in names
    assert "read" in names
    assert "grep" in names
    assert "code_search" in names
    refute "ext__beam__eval" in names
    refute "ext__beam__sql" in names
  end

  test "event and auth artifacts resolve under Host.data_dir" do
    Handbean.Host.put!(%{data_dir: "/tmp/mob-data"})

    assert Handbean.EventRecorder.event_path("s1") ==
             "/tmp/mob-data/.handbean/events/s1.jsonl"

    assert Handbean.Agent.Auth.Storage.file_path() ==
             "/tmp/mob-data/.handbean/auth.json"
  end
end
