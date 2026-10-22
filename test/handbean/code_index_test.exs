defmodule Handbean.CodeIndexTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Subagent.Profile
  alias Handbean.CodeIndex
  alias Handbean.CodeIndex.{Chunk, Location, Scan, Search, Store, Sync}
  alias Handbean.Host
  alias Handbean.Security.PathValidator
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

  test "ignore files never follow symlinks outside the authorized root", %{root: root} do
    outside =
      Path.join(Path.dirname(root), "ignore-outside-#{System.unique_integer([:positive])}")

    sensitive_dir =
      Path.join(Path.dirname(root), "ignore-sensitive-#{System.unique_integer([:positive])}/.aws")

    File.mkdir_p!(sensitive_dir)
    ordinary_target = Path.join(outside, "ordinary-ignore")
    sensitive_target = Path.join(sensitive_dir, "credentials")
    File.mkdir_p!(outside)
    File.write!(ordinary_target, "safe.ex\n")
    File.write!(sensitive_target, "safe.ex\n")
    File.write!(Path.join(root, "safe.ex"), "defmodule SafeIgnoreTarget, do: :ok")
    File.ln_s!(sensitive_target, Path.join(root, ".gitignore"))
    File.ln_s!(ordinary_target, Path.join(root, ".handbeanignore"))

    on_exit(fn ->
      File.rm_rf(outside)
      File.rm_rf(Path.dirname(sensitive_dir))
    end)

    assert {:ok, entries, meta} = Scan.list(root)
    assert Enum.any?(entries, &(&1.path == "safe.ex"))
    assert meta.ignore.parse_error
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
    assert Store.meta(store, "workspace_root") == PathValidator.resolve_symlink(root)
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

  test "busy internal hybrid search filters pending embeddings and cached vectors to its path", %{
    root: root
  } do
    File.write!(
      Path.join(root, "first.ex"),
      "defmodule FirstVector, do: def first_marker, do: :ok"
    )

    File.write!(
      Path.join(root, "second.ex"),
      "defmodule SecondVector, do: def second_marker, do: :ok"
    )

    sent = Agent.start_link(fn -> [] end) |> elem(1)

    embedder = fn texts, _config ->
      Agent.update(sent, fn calls -> calls ++ [texts] end)
      {:ok, Enum.map(texts, fn _ -> [1.0, 0.0] end)}
    end

    hybrid_opts = [
      budget_ms: 5_000,
      mode: :hybrid,
      embedder: Handbean.CodeIndexTest.FakeEmbedder,
      embedder_fun: embedder
    ]

    assert {:ok, _} = CodeIndex.search(root, "ws-vector-scope", "first_marker", hybrid_opts)
    assert {:ok, dir} = CodeIndex.index_dir(root, "ws-vector-scope")
    assert {:ok, store} = Store.open(dir, root, "ws-vector-scope")

    assert :ok =
             Exqlite.Sqlite3.execute(
               store.db,
               "DELETE FROM embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE path = 'first.ex')"
             )

    Store.close(store)
    Agent.update(sent, fn _ -> [] end)
    assert Sync.claim("ws-vector-scope") == :ok

    result =
      try do
        CodeIndex.search(
          root,
          "ws-vector-scope",
          "second_marker",
          Keyword.put(hybrid_opts, :path, "first.ex")
        )
      after
        Sync.release("ws-vector-scope")
      end

    assert {:ok, %{hits: hits}} = result
    assert Enum.all?(hits, &(&1.path == "first.ex"))
    [pending_batch, ["second_marker"]] = Agent.get(sent, & &1)
    assert Enum.any?(pending_batch, &String.contains?(&1, "first_marker"))
    refute Enum.any?(pending_batch, &String.contains?(&1, "second_marker"))
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

  test "external code_search keeps directory and single-file indexes in host data", %{
    root: root,
    data: data
  } do
    for scope <- [:directory, :file] do
      external =
        Path.join(
          Path.dirname(root),
          "code_index_external_#{scope}_#{System.unique_integer([:positive])}"
        )

      source = Path.join(external, "external.ex")
      File.mkdir_p!(external)
      sibling = Path.join(external, "sibling.ex")
      nested = Path.join(external, "nested/child.ex")
      File.mkdir_p!(Path.dirname(nested))
      File.write!(source, "defmodule ExternalScope, do: def boundary_symbol, do: :ok")
      File.write!(sibling, "defmodule SiblingScope, do: def sibling_symbol, do: :ok")
      File.write!(nested, "defmodule NestedScope, do: def nested_symbol, do: :ok")
      on_exit(fn -> File.rm_rf(external) end)

      requested_path = if scope == :directory, do: external, else: source
      before = tree_paths(external)

      assert {:ok, text, details} =
               CodeSearch.execute(
                 %{"query" => "boundary_symbol", "path" => requested_path},
                 %{
                   working_directory: root,
                   workspace_id: "source-workspace",
                   approval_mode: :yolo
                 }
               )

      assert text =~ source
      assert details.file_path == source
      assert tree_paths(external) == before
      refute File.exists?(Path.join(external, ".handbean"))
      refute File.exists?(Path.join(external, ".handbean-index-write-probe"))

      id =
        external_workspace_id(external, if(scope == :file, do: "external.ex", else: nil))

      assert {:ok, index_dir} = Location.resolve(external, id, storage: :host_data)
      assert {:ok, store} = Store.open(index_dir, external, id)

      expected_paths =
        if scope == :directory,
          do: ["external.ex", "nested/child.ex", "sibling.ex"],
          else: ["external.ex"]

      assert Enum.sort(Store.paths(store)) == expected_paths
      Store.close(store)
    end

    assert Path.wildcard(Path.join([data, ".handbean", "code-index", "**", "index.sqlite"])) != []
  end

  test "external code_search never indexes sensitive paths in yolo or with an exact grant", %{
    root: root
  } do
    for mode <- [:yolo, :grant] do
      external =
        Path.join(
          Path.dirname(root),
          "code_index_sensitive_#{mode}_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(external, ".aws"))

      File.write!(
        Path.join(external, "safe.ex"),
        "defmodule PublicCode, do: def visible, do: :ok"
      )

      File.write!(Path.join(external, ".env.staging"), "SECRET_ENV_MARKER")
      File.write!(Path.join(external, ".netrc"), "SECRET_NETRC_MARKER")
      File.write!(Path.join(external, ".aws/credentials"), "SECRET_AWS_MARKER")
      on_exit(fn -> File.rm_rf(external) end)

      id = external_workspace_id(external)
      assert {:ok, index_dir} = Location.resolve(external, id, storage: :host_data)
      assert {:ok, seeded} = Store.open(index_dir, external, id)

      assert :ok =
               Store.replace_file(
                 seeded,
                 %{
                   path: ".netrc",
                   size: 19,
                   content_hash: "legacy-sensitive",
                   language: "text"
                 },
                 Chunk.split("SECRET_NETRC_MARKER", "text")
               )

      Store.close(seeded)

      input = %{"query" => "visible", "path" => external}

      base_context = %{
        working_directory: root,
        workspace_id: "source-workspace",
        conversation_id: "source-conversation",
        run_id: "source-run"
      }

      context =
        case mode do
          :yolo ->
            Map.put(base_context, :approval_mode, :yolo)

          :grant ->
            call = %{id: "sensitive-search", name: "code_search", input: input}
            requirement = Handbean.Permissions.Boundary.requirement(call, base_context)
            grant = Handbean.Permissions.Boundary.grant(call, base_context, requirement, :human)

            base_context
            |> Map.put(:tool_execution_grants, %{call.id => grant})
            |> Handbean.Permissions.Boundary.invocation_context(call)
        end

      assert {:ok, text, _details} = CodeSearch.execute(input, context)
      assert text =~ "safe.ex"

      assert {:ok, store} = Store.open(index_dir, external, id)
      assert Store.paths(store) == ["safe.ex"]
      assert Store.search_fts(store, "SECRET_ENV_MARKER", 10) == []
      assert Store.search_fts(store, "SECRET_NETRC_MARKER", 10) == []
      assert Store.search_fts(store, "SECRET_AWS_MARKER", 10) == []
      Store.close(store)
    end
  end

  test "external scoped search fails closed while its writer is busy", %{root: root} do
    external =
      Path.join(Path.dirname(root), "code_index_busy_#{System.unique_integer([:positive])}")

    File.mkdir_p!(external)
    File.write!(Path.join(external, "only.ex"), "defmodule BusyScope, do: def visible, do: :ok")
    on_exit(fn -> File.rm_rf(external) end)

    id = external_workspace_id(external, "only.ex")
    assert Sync.claim(id) == :ok

    try do
      assert {:error, :index_scope_unavailable} =
               CodeIndex.search(external, id, "visible",
                 path: "only.ex",
                 storage: :host_data,
                 require_scope_sync: true,
                 budget_ms: 5_000
               )
    after
      Sync.release(id)
    end
  end

  test "external scoped search stops when stale-cache cleanup cannot commit", %{
    root: root
  } do
    external =
      Path.join(Path.dirname(root), "code_index_cleanup_#{System.unique_integer([:positive])}")

    File.mkdir_p!(external)

    File.write!(
      Path.join(external, "safe.ex"),
      "defmodule CleanupScope, do: def visible, do: :ok"
    )

    File.write!(Path.join(external, ".netrc"), "LEGACY_SECRET_MARKER")
    on_exit(fn -> File.rm_rf(external) end)

    id = external_workspace_id(external)
    opts = [storage: :host_data, require_scope_sync: true, budget_ms: 5_000]
    assert {:ok, _} = CodeIndex.search(external, id, "visible", opts)
    assert {:ok, dir} = Location.resolve(external, id, storage: :host_data)
    assert {:ok, blocker} = Store.open(dir, external, id)

    assert :ok =
             Store.replace_file(
               blocker,
               %{
                 path: ".netrc",
                 size: 20,
                 content_hash: "legacy-sensitive",
                 language: "text"
               },
               Chunk.split("LEGACY_SECRET_MARKER", "text")
             )

    assert {:ok, contender} = Store.open(dir, external, id)
    assert :ok = Exqlite.Sqlite3.execute(blocker.db, "BEGIN IMMEDIATE")

    try do
      assert %{status: :stale, safety: :failed} =
               Sync.sync(contender, external, 5_000, opts)

      Store.close(contender)

      assert {:error, :index_scope_unavailable} =
               CodeIndex.search(external, id, "visible", opts)
    after
      :ok = Exqlite.Sqlite3.execute(blocker.db, "ROLLBACK")
      Store.close(blocker)
    end

    assert {:ok, _} = CodeIndex.search(external, id, "visible", opts)
    assert {:ok, cleaned} = Store.open(dir, external, id)
    refute ".netrc" in Store.paths(cleaned)
    Store.close(cleaned)
  end

  test "concurrent exact-file searches use isolated indexes", %{root: root} do
    external =
      Path.join(Path.dirname(root), "code_index_concurrent_#{System.unique_integer([:positive])}")

    first = Path.join(external, "first.ex")
    second = Path.join(external, "second.ex")
    File.mkdir_p!(external)
    File.write!(first, "defmodule FirstScope, do: def first_symbol, do: :ok")
    File.write!(second, "defmodule SecondScope, do: def second_symbol, do: :ok")
    on_exit(fn -> File.rm_rf(external) end)

    [first_result, second_result] =
      [{first, "first_symbol"}, {second, "second_symbol"}]
      |> Task.async_stream(
        fn {path, query} ->
          CodeSearch.execute(
            %{"query" => query, "path" => path},
            %{
              working_directory: root,
              workspace_id: "source-workspace",
              approval_mode: :yolo
            }
          )
        end,
        ordered: true,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert {:ok, first_text, %{file_path: ^first}} = first_result
    assert first_text =~ first
    refute first_text =~ second
    assert {:ok, second_text, %{file_path: ^second}} = second_result
    assert second_text =~ second
    refute second_text =~ first

    for path <- [first, second] do
      name = Path.basename(path)
      id = external_workspace_id(external, name)
      assert {:ok, dir} = Location.resolve(external, id, storage: :host_data)
      assert {:ok, store} = Store.open(dir, external, id)
      assert Store.paths(store) == [name]
      Store.close(store)
    end
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

  defp external_workspace_id(root, scope_path \\ nil) do
    id = "path-" <> short_path_hash(root)
    if scope_path, do: id <> "-scope-" <> short_path_hash(scope_path), else: id
  end

  defp short_path_hash(path) do
    :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp tree_paths(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
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
