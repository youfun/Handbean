defmodule Handbean.CodeIndexTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Subagent.Profile
  alias Handbean.CodeIndex
  alias Handbean.CodeIndex.{Chunk, Location, Scan, Search, Store, Sync}
  alias Handbean.Host
  alias Handbean.Tool.Builtin.CodeSearch

  setup do
    previous = Application.get_env(:handbean, :host)
    root = Path.join(System.tmp_dir!(), "code_index_#{System.unique_integer([:positive])}")
    data = Path.join(System.tmp_dir!(), "code_index_data_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(data)
    Host.put!(%{data_dir: data, shell: false})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf(root)
      File.rm_rf(data)
    end)

    %{root: root, data: data}
  end

  test "chunks elixir defs and marks secrets", %{root: _root} do
    source = """
    defmodule Demo do
      def pull(repo) do
        repo
      end

      def token, do: "api_key=supersecretvalue"
    end
    """

    chunks = Chunk.split(source, "elixir")
    symbols = Enum.map(chunks, & &1.symbol)
    assert "Demo" in symbols
    assert "pull" in symbols
    assert Enum.any?(chunks, &(&1.embed_skip and &1.symbol == "token"))
  end

  test "gitignore parse failure still applies the directory denylist", %{root: root} do
    File.mkdir_p!(Path.join(root, "deps/left"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "deps/left/secret.ex"), "defmodule Hidden, do: :ok")
    File.write!(Path.join(root, "lib/keep.ex"), "defmodule Keep, do: :ok")
    File.mkdir_p!(Path.join(root, ".gitignore"))

    assert {:ok, entries, meta} = Scan.list(root)
    assert meta.ignore.parse_error
    refute Enum.any?(entries, &String.starts_with?(&1.path, "deps/"))
    assert Enum.any?(entries, &(&1.path == "lib/keep.ex"))
  end

  test "does not follow a symlinked file", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "code_index_out_#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "out.ex"), "defmodule Out, do: :ok")
    File.mkdir_p!(Path.join(root, "lib"))
    File.ln_s!(Path.join(outside, "out.ex"), Path.join(root, "lib/out.ex"))
    File.write!(Path.join(root, "lib/in.ex"), "defmodule In, do: :ok")

    assert {:ok, entries, _} = Scan.list(root)
    refute Enum.any?(entries, &(&1.path == "lib/out.ex"))
    assert Enum.any?(entries, &(&1.path == "lib/in.ex"))
    File.rm_rf(outside)
  end

  test "imported workspace index lands in data_dir, not the copy", %{root: root, data: data} do
    imported = Path.join(root, "imported_workspaces/req/app")
    File.mkdir_p!(Path.join(imported, "lib"))
    File.write!(Path.join(imported, "lib/app.ex"), "defmodule App, do: def hello, do: :ok")

    assert {:ok, dir} = Location.resolve(imported, "ws-import")
    assert String.starts_with?(dir, Path.join(data, ".handbean/code-index/ws-import"))
    refute String.contains?(dir, "imported_workspaces")

    assert {:ok, result} = CodeIndex.search(imported, "ws-import", "hello", budget_ms: 5_000)
    assert result.mode == :keyword
    assert Enum.any?(result.hits, &(&1.path == "lib/app.ex"))
    refute File.dir?(Path.join(imported, ".handbean/code-index"))
  end

  test "same workspace keeps divergent checkouts in distinct indexes", %{root: root} do
    first = Path.join(root, "checkout-a")
    second = Path.join(root, "checkout-b")
    File.mkdir_p!(Path.join(first, "lib"))
    File.mkdir_p!(Path.join(second, "lib"))
    File.write!(Path.join(first, "lib/branch.ex"), "defmodule AlphaOnly, do: :ok")
    File.write!(Path.join(second, "lib/branch.ex"), "defmodule BetaOnly, do: :ok")

    assert {:ok, first_dir} = CodeIndex.index_dir(first, "shared-workspace")
    assert {:ok, second_dir} = CodeIndex.index_dir(second, "shared-workspace")
    refute first_dir == second_dir

    assert {:ok, first_result} =
             CodeIndex.search(first, "shared-workspace", "AlphaOnly", budget_ms: 5_000)

    assert {:ok, second_result} =
             CodeIndex.search(second, "shared-workspace", "AlphaOnly", budget_ms: 5_000)

    assert Enum.any?(first_result.hits, &(&1.path == "lib/branch.ex"))
    assert second_result.hits == []
  end

  test "identity mismatch refuses the existing database", %{root: root} do
    File.write!(Path.join(root, "lib.ex"), "defmodule A, do: :ok")
    File.mkdir_p!(Path.join(root, "lib"))
    assert {:ok, dir} = CodeIndex.index_dir(root, "ws-a")
    assert {:ok, store} = Store.open(dir, root, "ws-a")
    Store.close(store)

    assert {:error, :identity_mismatch} = Store.open(dir, root, "ws-b")
    assert {:error, :identity_mismatch} = CodeIndex.open_store(dir, "/other", "ws-b")
    assert {:ok, kept} = Store.open(dir, root, "ws-a")
    Store.close(kept)
    assert {:ok, rebuilt} = Store.rebuild(dir, "/other", "ws-b")
    assert Store.meta(rebuilt, "workspace_id") == "ws-b"
    Store.close(rebuilt)
  end

  test "search rebinds a same-root index after the workspace id changes", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "lib/auth.ex"), """
    defmodule Auth do
      def middleware(conn), do: conn
    end
    """)

    assert {:ok, _} = CodeIndex.search(root, "ws-old", "middleware", budget_ms: 5_000)
    assert {:ok, dir} = CodeIndex.index_dir(root, "ws-old")
    assert File.exists?(Path.join(dir, "index.sqlite"))

    assert {:ok, result} = CodeIndex.search(root, "ws-new", "middleware", budget_ms: 5_000)
    assert Enum.any?(result.hits, &(&1.path == "lib/auth.ex"))

    assert {:ok, store} = Store.open(dir, root, "ws-new")
    assert Store.meta(store, "workspace_id") == "ws-new"
    assert Store.meta(store, "workspace_root") == Path.expand(root)
    Store.close(store)
  end

  test "keyword search works with shell false and does not need git", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib/handbean"))

    File.write!(Path.join(root, "lib/handbean/git.ex"), """
    defmodule Handbean.Git do
      def pull(repo, opts \\\\ []) do
        repo
      end
    end
    """)

    assert {:ok, result} = CodeIndex.search(root, "ws-kw", "pull", budget_ms: 5_000)
    assert result.mode == :keyword
    assert [%{path: "lib/handbean/git.ex", symbol: "pull"} | _] = result.hits
  end

  test "empty vector side does not dilute fts ranks" do
    fts = [
      %{path: "a.ex", start_line: 1, end_line: 2, symbol: "alpha", score: 0.1},
      %{path: "b.ex", start_line: 3, end_line: 4, symbol: "beta", score: 0.2}
    ]

    assert Search.fuse(fts, [], 2) == Search.fuse(fts, [], 2)
    fused = Search.fuse(fts, [], 2)
    assert Enum.map(fused, & &1.path) == ["a.ex", "b.ex"]
    assert hd(fused).score == 1 / 61
  end

  test "sync stops when cancelled and releases the writer", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib"))

    for n <- 1..30 do
      File.write!(
        Path.join(root, "lib/f#{n}.ex"),
        "defmodule F#{n} do\n  def item_#{n}, do: :ok\nend\n"
      )
    end

    parent = self()

    task =
      Task.async(fn ->
        CodeIndex.search(root, "ws-cancel", "item_1",
          budget_ms: 30_000,
          cancel: fn -> not Process.alive?(parent) end
        )
      end)

    Process.sleep(20)
    Task.shutdown(task, :brutal_kill)
    assert Sync.claim("ws-cancel") == :ok
    Sync.release("ws-cancel")
  end

  test "one writer per workspace", %{root: root} do
    assert Sync.claim("ws-lock") == :ok
    assert Sync.claim("ws-lock") == :busy
    other = Task.async(fn -> Sync.claim("ws-lock") end)
    assert Task.await(other) == :busy
    Sync.release("ws-lock")
    assert Sync.claim("ws-lock") == :ok
    Sync.release("ws-lock")
    refute File.dir?(root) == false
  end

  test "secret chunks are skipped by the embedder fixture", %{root: root} do
    File.write!(Path.join(root, "secrets.ex"), """
    defmodule Secrets do
      def token, do: "api_key=supersecretvalue"
      def visible, do: :ok
    end
    """)

    sent = Agent.start_link(fn -> [] end) |> elem(1)

    embedder = fn texts, _config ->
      Agent.update(sent, fn acc -> acc ++ texts end)
      {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)}
    end

    assert {:ok, _} =
             CodeIndex.search(root, "ws-secret", "visible",
               budget_ms: 5_000,
               mode: :hybrid,
               embedder: Handbean.CodeIndexTest.FakeEmbedder,
               embedder_fun: embedder
             )

    uploaded = Agent.get(sent, & &1)
    assert uploaded != []
    refute Enum.any?(uploaded, &String.contains?(&1, "supersecretvalue"))
    assert Enum.any?(uploaded, &String.contains?(&1, "visible"))
  end

  test "code_search tool returns a path and symbol, not chunk text", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "lib/auth.ex"), """
    defmodule Auth do
      def middleware(conn), do: conn
    end
    """)

    assert {:ok, text, details} =
             CodeSearch.execute(%{"query" => "middleware"}, %{
               working_directory: root,
               workspace_id: "ws-tool"
             })

    assert text =~ "lib/auth.ex"
    assert text =~ "middleware"
    assert text =~ "mode=keyword"
    assert text =~ "Do not treat this as file contents."
    refute text =~ "defmodule Auth"
    assert details.file_path == "lib/auth.ex"
  end

  test "removing a workspace deletes its local code index", %{root: root} do
    alias Handbean.WorkspaceStore

    previous = System.get_env("HANDBEAN_WORKSPACES_FILE")

    storage =
      Path.join(System.tmp_dir!(), "workspaces_#{System.unique_integer([:positive])}.json")

    System.put_env("HANDBEAN_WORKSPACES_FILE", storage)

    on_exit(fn ->
      if previous,
        do: System.put_env("HANDBEAN_WORKSPACES_FILE", previous),
        else: System.delete_env("HANDBEAN_WORKSPACES_FILE")

      File.rm(storage)
    end)

    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(
      Path.join(root, "lib/auth.ex"),
      "defmodule Auth, do: def middleware(conn), do: conn"
    )

    assert {:ok, workspace} = WorkspaceStore.add(root, name: "Indexed")
    assert {:ok, _} = CodeIndex.search(root, workspace["id"], "middleware", budget_ms: 5_000)
    assert {:ok, dir} = CodeIndex.index_dir(root, workspace["id"])
    assert File.exists?(Path.join(dir, "index.sqlite"))

    assert {:ok, _removed} = WorkspaceStore.remove(workspace["id"])
    refute File.exists?(Path.join(dir, "index.sqlite"))
    refute File.exists?(Path.join(dir, "index.sqlite-wal"))
    refute File.exists?(Path.join(dir, "index.sqlite-shm"))
  end

  test "host seeds include code_search on desktop and phone" do
    Host.put!(%{shell: true, browser_backend: :cli})
    assert "code_search" in names()

    Host.put!(%{
      shell: false,
      browser_backend: :webview,
      artifact_delivery_backend: Handbean.ArtifactDelivery,
      host_script: true
    })

    assert "code_search" in names()
  end

  test "delegation and collaboration allow the tool" do
    allowed =
      Handbean.Agent.Delegation.Policy.allowed_tools(
        ["code_search", "bash"],
        Profile.researcher()
      )

    assert "code_search" in allowed
    refute "bash" in allowed
  end

  defp names do
    Enum.map(Handbean.Agent.default_tools(), & &1.name())
  end
end

defmodule Handbean.CodeIndexTest.FakeEmbedder do
  @behaviour Handbean.CodeIndex.Embedder

  @impl true
  def config(opts) do
    {:ok,
     %{
       model: "fake",
       base_url: "http://unused",
       api_key: "not-a-secret",
       fun: opts[:embedder_fun]
     }}
  end

  @impl true
  def embed(texts, config) do
    config.fun.(texts, config)
  end
end
