# Isolated WorkspaceLive browser fixture.
#
# Starts this project's real Endpoint + Coordinator on a dedicated port
# (default 4017). The LLM is a local OpenAI-compatible hold server — no
# external models, no real ~/.handbean history, no port 4000.
#
# Start (from `sigil/`):
#
#   MIX_ENV=dev HANDBEAN_FIXTURE_PORT=4017 mix run --no-start scripts/workspace_live_browser_fixture.exs
#
# Or: `scripts/workspace_live_browser_fixture.sh`
#
# Control files (printed at boot):
#   touch $FIXTURE_RELEASE   — finish the held provider stream
#   touch $FIXTURE_STOP       — stop this fixture (Endpoint + hold server)
#
# Do not load ExUnit test modules. Pattern matches the native Bandit SSE
# hold used in probe tests (chat/completions + chunk then wait).

defmodule Handbean.Script.WorkspaceLiveHoldPlug do
  @behaviour Plug

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", path_info: ["health"]} = conn, _opts) do
    Plug.Conn.send_resp(conn, 200, "ok")
  end

  def call(conn, opts) do
    if chat_completions?(conn) do
      hold_stream(conn, opts)
    else
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  defp chat_completions?(%{path_info: path}) do
    path == ["v1", "chat", "completions"] or path == ["chat", "completions"]
  end

  defp hold_stream(conn, opts) do
    release = Keyword.fetch!(opts, :release)
    stop = Keyword.fetch!(opts, :stop)
    held = Keyword.fetch!(opts, :held)
    File.write!(held, "held\n")

    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    {:ok, conn} =
      Plug.Conn.chunk(
        conn,
        "data: " <>
          Handbean.JSON.encode!(%{
            choices: [%{delta: %{content: "Fixture hold"}, finish_reason: nil}]
          }) <> "\n\n"
      )

    await_file(release, stop)

    reply =
      "data: " <>
        Handbean.JSON.encode!(%{
          choices: [%{delta: %{content: " done"}, finish_reason: nil}]
        }) <>
        "\n\n" <>
        "data: " <>
        Handbean.JSON.encode!(%{choices: [%{delta: %{}, finish_reason: "stop"}]}) <>
        "\n\ndata: [DONE]\n\n"

    {:ok, conn} = Plug.Conn.chunk(conn, reply)
    conn
  end

  defp await_file(release, stop) do
    cond do
      File.exists?(release) ->
        :ok

      File.exists?(stop) ->
        :ok

      true ->
        Process.sleep(200)
        await_file(release, stop)
    end
  end
end

home =
  System.get_env("HANDBEAN_FIXTURE_HOME") ||
    Path.join(System.tmp_dir!(), "handbean-ws-live-fixture-#{System.unique_integer([:positive])}")

File.mkdir_p!(home)
workspace = Path.join(home, "workspace")
File.mkdir_p!(workspace)
ctrl = Path.join(home, "ctrl")
File.mkdir_p!(ctrl)
release = Path.join(ctrl, "release")
stop = Path.join(ctrl, "stop")
held = Path.join(ctrl, "held")
port = String.to_integer(System.get_env("HANDBEAN_FIXTURE_PORT") || "4017")

System.put_env("HOME", home)
System.put_env("HANDBEAN_WORKSPACE", workspace)
System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(home, "workspaces.json"))
System.put_env("HANDBEAN_MODELS_FILE", Path.join(home, "models.json"))
System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", Path.join(home, "settings.json"))
System.delete_env("PHX_SERVER")
System.delete_env("OPENAI_API_KEY")

{:ok, hold_pid} =
  Bandit.start_link(
    plug: {Handbean.Script.WorkspaceLiveHoldPlug, release: release, stop: stop, held: held},
    ip: {127, 0, 0, 1},
    port: 0
  )

{:ok, {_ip, hold_port}} = ThousandIsland.listener_info(hold_pid)

File.write!(
  System.get_env("HANDBEAN_MODELS_FILE"),
  Handbean.JSON.encode!(%{
    "defaultProvider" => "fixture",
    "defaultModel" => "fixture-hold",
    "providers" => %{
      "fixture" => %{
        "api" => "openai-chat-completions",
        "provider" => "openai-compat",
        "apiKey" => "fixture-key",
        "baseUrl" => "http://127.0.0.1:#{hold_port}/v1",
        "models" => [%{"id" => "fixture-hold", "name" => "Local hold fixture"}]
      }
    }
  })
)

host = %{data_dir: home, shell: false, mcp: false, browser_backend: nil}

host =
  case Handbean.Host.file_manager_backend() do
    nil -> host
    backend -> Map.put(host, :file_manager_backend, backend)
  end

Handbean.Host.put!(host)

endpoint_cfg =
  Application.get_env(:handbean, HandbeanWeb.Endpoint)
  |> Keyword.merge(
    http: [ip: {127, 0, 0, 1}, port: port],
    url: [host: "127.0.0.1", port: port],
    server: true,
    code_reloader: false,
    watchers: [],
    check_origin: false
  )

Application.put_env(:handbean, HandbeanWeb.Endpoint, endpoint_cfg)

repo_cfg =
  Application.get_env(:handbean, Handbean.Repo)
  |> Keyword.merge(
    database: Path.join(home, "fixture.db"),
    pool_size: 1,
    busy_timeout: 15_000,
    journal_mode: :wal,
    cache_size: -64000,
    temp_store: :memory
  )

Application.put_env(:handbean, Handbean.Repo, repo_cfg)
Application.put_env(:handbean, :extension_hot_reload, false)

{:ok, _} = Application.ensure_all_started(:handbean)

migrations = Path.join(File.cwd!(), "priv/repo/migrations")
_ = Ecto.Migrator.run(Handbean.Repo, migrations, :up, all: true)

{:ok, _ws} = Handbean.WorkspaceStore.ensure_default!()

{:ok, conversation} =
  Handbean.ConversationStore.create("default", title: "Steer browser fixture")

url = "http://127.0.0.1:#{port}/w/default/c/#{conversation["id"]}"
File.write!(Path.join(ctrl, "url"), url <> "\n")
File.write!(Path.join(ctrl, "pid"), "#{System.pid()}\n")

IO.puts("""
FIXTURE_HOME=#{home}
FIXTURE_URL=#{url}
FIXTURE_HOLD=http://127.0.0.1:#{hold_port}/health
FIXTURE_RELEASE=#{release}
FIXTURE_STOP=#{stop}
FIXTURE_PID=#{System.pid()}

Send in the browser to start a real Coordinator run (provider holds after the first stream chunk).
touch FIXTURE_RELEASE to finish the hold. touch FIXTURE_STOP to shut down this process.
""")

parent = self()

spawn(fn ->
  Stream.repeatedly(fn ->
    Process.sleep(200)
    File.exists?(stop)
  end)
  |> Enum.find(& &1)

  send(parent, :fixture_stop)
end)

receive do
  :fixture_stop -> :ok
end

_ = Supervisor.stop(hold_pid, :normal)
:ok = Application.stop(:handbean)
IO.puts("FIXTURE_STOPPED")
