defmodule Handbean.CodeIndex.Store do
  @moduledoc """
  SQLite store for one workspace code index.

  Not `Handbean.Repo`. FTS5 uses an external-content table and is updated in
  the same transaction as `chunks`.
  """

  alias Exqlite.Sqlite3

  @schema_version "2"
  @db "index.sqlite"

  @type t :: %{
          db: reference(),
          path: Path.t(),
          workspace_id: String.t(),
          workspace_root: String.t()
        }

  @spec open(Path.t(), Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def open(dir, workspace_root, workspace_id) do
    with :ok <- File.mkdir_p(dir),
         {:ok, db} <- Sqlite3.open(Path.join(dir, @db)) do
      store = %{
        db: db,
        path: Path.join(dir, @db),
        workspace_id: workspace_id,
        workspace_root:
          Handbean.Security.PathValidator.resolve_symlink(Path.expand(workspace_root))
      }

      case initialize(store) do
        :ok -> {:ok, store}
        {:error, reason} -> close_with_error(store, reason)
        reason -> close_with_error(store, reason)
      end
    end
  end

  defp initialize(store) do
    with :ok <- Sqlite3.execute(store.db, "PRAGMA journal_mode = WAL"),
         :ok <- Sqlite3.execute(store.db, "PRAGMA foreign_keys = ON"),
         :ok <- migrate(store.db) do
      bind_identity(store)
    end
  end

  defp bind_identity(store) do
    case identity(store.db) do
      {:empty, _} ->
        with :ok <- put_meta(store, "workspace_id", store.workspace_id),
             :ok <- put_meta(store, "workspace_root", store.workspace_root),
             :ok <- put_meta(store, "checkout_path", store.workspace_root),
             :ok <- put_meta(store, "schema", @schema_version) do
          :ok
        end

      {:ok, id, root} when id == store.workspace_id and root == store.workspace_root ->
        with :ok <- put_meta(store, "checkout_path", store.workspace_root),
             :ok <- put_meta(store, "schema", @schema_version) do
          :ok
        end

      {:ok, _, _} ->
        {:error, :identity_mismatch}
    end
  end

  defp close_with_error(store, reason) do
    Sqlite3.close(store.db)
    {:error, reason}
  end

  @spec close(t()) :: :ok
  def close(%{db: db}), do: Sqlite3.close(db)

  @doc "Read stored identity without binding it to a caller."
  @spec read_identity(Path.t()) :: {:ok, String.t() | nil, String.t() | nil} | {:error, term()}
  def read_identity(dir) do
    case Sqlite3.open(Path.join(dir, @db)) do
      {:ok, db} ->
        try do
          case identity(db) do
            {:empty, _} -> {:ok, nil, nil}
            {:ok, id, root} -> {:ok, id, root}
          end
        after
          Sqlite3.close(db)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec rebuild(Path.t(), Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def rebuild(dir, workspace_root, workspace_id) do
    path = Path.join(dir, @db)
    File.rm(path)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
    open(dir, workspace_root, workspace_id)
  end

  @spec file_hash(t(), String.t()) :: String.t() | nil
  def file_hash(store, path) do
    case one(store, "SELECT content_hash FROM files WHERE path = ?1", [path]) do
      {:ok, [hash]} -> hash
      _ -> nil
    end
  end

  @spec paths(t()) :: [String.t()]
  def paths(store) do
    store
    |> all("SELECT path FROM files", [])
    |> Enum.map(fn [path] -> path end)
  end

  @spec replace_file(t(), map(), [map()]) :: :ok | {:error, term()}
  def replace_file(store, file, chunks) when is_map(file) and is_list(chunks) do
    with :ok <- exec(store, "BEGIN IMMEDIATE"),
         :ok <- delete_path(store, file.path),
         :ok <-
           exec(
             store,
             """
             INSERT INTO files(path, size, content_hash, language)
             VALUES (?1, ?2, ?3, ?4)
             """,
             [file.path, file.size, file.content_hash, file.language]
           ) do
      result =
        Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
          case insert_chunk(store, file.path, chunk) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok ->
          exec(store, "COMMIT")

        {:error, reason} ->
          _ = exec(store, "ROLLBACK")
          {:error, reason}
      end
    else
      {:error, reason} ->
        _ = exec(store, "ROLLBACK")
        {:error, reason}
    end
  end

  @spec delete_path(t(), String.t()) :: :ok | {:error, term()}
  def delete_path(store, path) do
    with :ok <-
           exec(
             store,
             """
             INSERT INTO chunks_fts(chunks_fts, rowid, text, symbol, path)
             SELECT 'delete', id, text, symbol, path FROM chunks WHERE path = ?1
             """,
             [path]
           ),
         :ok <-
           exec(
             store,
             "DELETE FROM embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE path = ?1)",
             [path]
           ),
         :ok <- exec(store, "DELETE FROM chunks WHERE path = ?1", [path]) do
      exec(store, "DELETE FROM files WHERE path = ?1", [path])
    end
  end

  @spec remove_missing(t(), [String.t()]) :: :ok | {:error, term()}
  def remove_missing(store, live_paths) do
    live = MapSet.new(live_paths)

    store
    |> paths()
    |> Enum.reject(&MapSet.member?(live, &1))
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case transaction(store, fn -> delete_path(store, path) end) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec search_fts(t(), String.t(), pos_integer()) :: [map()]
  def search_fts(store, query, limit) do
    sql = """
    SELECT c.path, c.start_line, c.end_line, c.symbol, c.kind, bm25(chunks_fts) AS rank
    FROM chunks_fts
    JOIN chunks c ON c.id = chunks_fts.rowid
    WHERE chunks_fts MATCH ?1
    ORDER BY rank
    LIMIT ?2
    """

    case all_ok(store, sql, [query, limit]) do
      {:ok, rows} -> Enum.map(rows, &hit_from_fts/1)
      {:error, _} -> []
    end
  end

  @spec embeddings_for_scan(t(), String.t(), pos_integer()) :: [map()]
  def embeddings_for_scan(store, model, limit) do
    sql = """
    SELECT c.id, c.path, c.start_line, c.end_line, c.symbol, c.kind, e.vector
    FROM embeddings e
    JOIN chunks c ON c.id = e.chunk_id
    WHERE e.model = ?1
    LIMIT ?2
    """

    case all_ok(store, sql, [model, limit]) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, path, start_line, end_line, symbol, kind, vector] ->
          %{
            id: id,
            path: path,
            start_line: start_line,
            end_line: end_line,
            symbol: symbol,
            kind: kind,
            vector: vector
          }
        end)

      {:error, _} ->
        []
    end
  end

  @spec put_embedding(t(), integer(), String.t(), integer(), binary()) :: :ok | {:error, term()}
  def put_embedding(store, chunk_id, model, dim, blob) do
    exec(
      store,
      """
      INSERT INTO embeddings(chunk_id, model, dim, vector)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(chunk_id, model) DO UPDATE SET dim = excluded.dim, vector = excluded.vector
      """,
      [chunk_id, model, dim, {:blob, blob}]
    )
  end

  @spec chunks_pending_embed(t(), String.t(), pos_integer()) :: [map()]
  def chunks_pending_embed(store, model, limit) do
    sql = """
    SELECT c.id, c.path, c.symbol, c.kind, c.text
    FROM chunks c
    LEFT JOIN embeddings e ON e.chunk_id = c.id AND e.model = ?1
    WHERE c.embed_skip = 0 AND e.chunk_id IS NULL
    LIMIT ?2
    """

    case all_ok(store, sql, [model, limit]) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, path, symbol, kind, text] ->
          %{id: id, path: path, symbol: symbol, kind: kind, text: text, embed_skip: false}
        end)

      {:error, _} ->
        []
    end
  end

  @spec put_meta(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def put_meta(store, key, value) when is_binary(key) and is_binary(value) do
    exec(
      store,
      """
      INSERT INTO meta(key, value) VALUES (?1, ?2)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      """,
      [key, value]
    )
  end

  @spec meta(t(), String.t()) :: String.t() | nil
  def meta(store, key) do
    case one(store, "SELECT value FROM meta WHERE key = ?1", [key]) do
      {:ok, [value]} -> value
      _ -> nil
    end
  end

  @spec meta_status(t()) :: map()
  def meta_status(store) do
    %{
      workspace_id: meta(store, "workspace_id"),
      workspace_root: meta(store, "workspace_root"),
      checkout_path: meta(store, "checkout_path") || meta(store, "workspace_root"),
      embedding_model: meta(store, "embedding_model"),
      last_sync: meta(store, "last_sync"),
      files: count(store, "files"),
      chunks: count(store, "chunks")
    }
  end

  defp insert_chunk(store, path, chunk) do
    with :ok <-
           exec(
             store,
             """
             INSERT INTO chunks(path, start_line, end_line, symbol, kind, text, text_hash, embed_skip)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             """,
             [
               path,
               chunk.start_line,
               chunk.end_line,
               chunk.symbol,
               chunk.kind,
               chunk.text,
               hash(chunk.text),
               if(chunk.embed_skip, do: 1, else: 0)
             ]
           ) do
      case one(store, "SELECT last_insert_rowid()", []) do
        {:ok, [id]} ->
          exec(
            store,
            """
            INSERT INTO chunks_fts(rowid, text, symbol, path) VALUES (?1, ?2, ?3, ?4)
            """,
            [id, chunk.text, chunk.symbol || "", path]
          )

        other ->
          other
      end
    end
  end

  defp identity(db) do
    store = %{db: db}

    id = meta(store, "workspace_id")
    root = meta(store, "workspace_root")

    if is_nil(id) and is_nil(root) do
      {:empty, nil}
    else
      {:ok, id, root}
    end
  end

  defp migrate(db) do
    [
      """
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        size INTEGER NOT NULL,
        content_hash TEXT NOT NULL,
        language TEXT NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL,
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        symbol TEXT,
        kind TEXT NOT NULL,
        text TEXT NOT NULL,
        text_hash TEXT NOT NULL,
        embed_skip INTEGER NOT NULL DEFAULT 0
      )
      """,
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text,
        symbol,
        path,
        content='chunks',
        content_rowid='id'
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS embeddings (
        chunk_id INTEGER NOT NULL,
        model TEXT NOT NULL,
        dim INTEGER NOT NULL,
        vector BLOB NOT NULL,
        PRIMARY KEY (chunk_id, model)
      )
      """
    ]
    |> Enum.reduce_while(:ok, fn sql, :ok ->
      case Sqlite3.execute(db, sql) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        reason -> {:halt, {:error, reason}}
      end
    end)
  end

  defp transaction(store, fun) do
    with :ok <- exec(store, "BEGIN IMMEDIATE") do
      case fun.() do
        :ok ->
          exec(store, "COMMIT")

        {:error, reason} ->
          _ = exec(store, "ROLLBACK")
          {:error, reason}
      end
    end
  end

  defp count(store, table) do
    case one(store, "SELECT COUNT(*) FROM #{table}", []) do
      {:ok, [n]} -> n
      _ -> 0
    end
  end

  defp hit_from_fts([path, start_line, end_line, symbol, kind, rank]) do
    %{
      path: path,
      start_line: start_line,
      end_line: end_line,
      symbol: symbol,
      kind: kind,
      rank: rank
    }
  end

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp exec(store, sql, args \\ []) do
    case Sqlite3.prepare(store.db, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- Sqlite3.bind(stmt, args),
               :done <- step_done(store.db, stmt) do
            :ok
          else
            {:error, reason} -> {:error, reason}
            reason -> {:error, reason}
          end

        _ = Sqlite3.release(store.db, stmt)
        result

      {:error, reason} ->
        {:error, reason}

      reason ->
        {:error, reason}
    end
  end

  defp step_done(db, stmt) do
    case Sqlite3.step(db, stmt) do
      :done -> :done
      {:row, _} -> step_done(db, stmt)
      other -> other
    end
  end

  defp one(store, sql, args) do
    case all_ok(store, sql, args) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  defp all(store, sql, args) do
    case all_ok(store, sql, args) do
      {:ok, rows} -> rows
      {:error, _} -> []
    end
  end

  defp all_ok(store, sql, args) do
    with {:ok, stmt} <- Sqlite3.prepare(store.db, sql),
         :ok <- Sqlite3.bind(stmt, args) do
      rows = fetch(store.db, stmt, [])
      Sqlite3.release(store.db, stmt)
      {:ok, Enum.reverse(rows)}
    end
  end

  defp fetch(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> fetch(db, stmt, [row | acc])
      :done -> acc
      {:error, _} -> acc
    end
  end
end
