defmodule Handbean.ConversationArtifacts do
  @moduledoc """
  Filesystem owner for recoverable artifacts associated with a conversation.

  Transcript, metadata, receipts, and session snapshots do not live here; they
  are canonical SQLite data. This root is only for files such as large saved
  tool inputs, reversible change snapshots, tool-result spills, and subagent
  descriptors.
  """

  alias Handbean.Security.PathValidator
  alias Handbean.Utils.SafeMap

  @tool_result_ref_prefix "conversation_artifact:tool-results/"
  @spill_prefix "spill-"
  @spill_suffix ".txt"
  @hash_bytes 32

  @type cleanup_result :: %{
          deleted: non_neg_integer(),
          freed_bytes: non_neg_integer(),
          retained_bytes: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec root() :: String.t()
  def root do
    Application.get_env(
      :handbean,
      :conversation_artifact_root,
      Path.join(Handbean.Host.data_dir(), ".handbean/conversation-artifacts")
    )
  end

  @doc "Persist a content-addressed large tool result for the current conversation."
  @spec persist_tool_result(binary(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def persist_tool_result(content, context, opts \\ [])
      when is_binary(content) and is_map(context) do
    with conversation_id when is_binary(conversation_id) <- conversation_id(context),
         true <- safe_id?(conversation_id),
         root when is_binary(root) and root != "" <- artifact_root(context),
         filename <- spill_filename(content),
         :ok <- validate_owned_path(root, conversation_id, filename) do
      with_root_lock(root, fn ->
        with true <- conversation_exists?(conversation_id, opts),
             :ok <- ensure_private_directories(root, conversation_id),
             path <- tool_result_path(root, conversation_id, filename),
             :ok <- persist_content_addressed(path, content) do
          {:ok, @tool_result_ref_prefix <> filename}
        else
          false -> {:error, :invalid_or_inactive_conversation}
          {:error, _reason} = error -> error
        end
      end)
    else
      nil -> {:error, :missing_conversation_id}
      false -> {:error, :invalid_conversation_id}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_artifact_root}
    end
  end

  @doc "Run a read while holding the lifecycle lock for the referenced conversation artifact."
  @spec with_tool_result(String.t(), map(), (String.t() -> result)) :: result | {:error, term()}
        when result: term()
  def with_tool_result(@tool_result_ref_prefix <> filename, context, fun)
      when is_map(context) and is_function(fun, 1) do
    with :ok <- validate_spill_filename(filename),
         conversation_id when is_binary(conversation_id) <- conversation_id(context),
         true <- safe_id?(conversation_id),
         root when is_binary(root) and root != "" <- artifact_root(context),
         :ok <- validate_owned_path(root, conversation_id, filename) do
      with_root_lock(root, fn ->
        path = tool_result_path(root, conversation_id, filename)

        with :ok <- validate_existing_directory(root),
             :ok <- validate_existing_directory(items_root(root)),
             :ok <- validate_existing_directory(item_root(root, conversation_id)),
             :ok <- validate_existing_directory(tool_results_root(root, conversation_id)),
             {:ok, %{type: :regular}} <- File.lstat(path) do
          fun.(path)
        else
          {:ok, _stat} -> {:error, :invalid_artifact_type}
          {:error, _reason} = error -> error
        end
      end)
    else
      nil -> {:error, :missing_conversation_id}
      false -> {:error, :invalid_conversation_id}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_artifact_root}
    end
  end

  def with_tool_result(_ref, _context, _fun), do: {:error, :invalid_artifact_ref}

  @doc "Whether a string uses the opaque conversation tool-result reference format."
  @spec tool_result_ref?(term()) :: boolean()
  def tool_result_ref?(@tool_result_ref_prefix <> _filename), do: true
  def tool_result_ref?(_value), do: false

  @doc false
  def persist_change_snapshot(conversation_id, change_id, content) when is_binary(content) do
    root = root()

    with :ok <- validate_snapshot_ids(conversation_id, change_id) do
      with_root_lock(root, fn ->
        with :ok <- ensure_snapshot_directories(root, conversation_id),
             path <- snapshot_path(root, conversation_id, change_id),
             :ok <- PathValidator.validate_under_root(path, snapshot_root(root, conversation_id)),
             :ok <- publish_snapshot(path, content) do
          :ok
        end
      end)
    end
  end

  @doc false
  def load_change_snapshot(conversation_id, change_id) do
    root = root()

    with :ok <- validate_snapshot_ids(conversation_id, change_id) do
      with_root_lock(root, fn ->
        with {:ok, path} <- existing_snapshot_path(root, conversation_id, change_id),
             do: File.read(path)
      end)
    end
  end

  @doc false
  def delete_uncommitted_change_snapshots([]), do: []

  def delete_uncommitted_change_snapshots(entries) when is_list(entries) do
    root = root()

    case with_root_lock(root, fn -> delete_uncommitted_snapshots(root, entries) end) do
      {:error, _reason} = error ->
        Enum.map(entries, fn {_conversation_id, _change_id, ref} -> {ref, error} end)

      results ->
        results
    end
  end

  defp delete_uncommitted_snapshots(root, entries) do
    paths =
      Enum.map(entries, fn {conversation_id, change_id, ref} ->
        result =
          with :ok <- validate_snapshot_ids(conversation_id, change_id),
               true <- ref == snapshot_ref(conversation_id, change_id),
               {:ok, path} <- existing_snapshot_path(root, conversation_id, change_id) do
            {:ok, path}
          else
            false -> {:error, :invalid_snapshot_ref}
            {:error, _reason} = error -> error
          end

        {ref, result}
      end)

    candidates = Enum.filter(paths, fn {_ref, result} -> match?({:ok, _}, result) end)

    deleted =
      if candidates == [] do
        %{}
      else
        case with_snapshot_scan_lock(fn -> delete_unreferenced_snapshots(candidates) end) do
          {:ok, results} -> Map.new(results)
          {:error, _reason} = error -> Map.new(candidates, fn {ref, _path} -> {ref, error} end)
        end
      end

    Enum.map(paths, fn
      {ref, {:ok, _path}} -> {ref, Map.fetch!(deleted, ref)}
      {ref, {:error, _reason} = error} -> {ref, error}
    end)
  end

  defp delete_unreferenced_snapshots(candidates) do
    with {:ok, refs} <- durable_snapshot_refs() do
      {:ok,
       Enum.map(candidates, fn {ref, {:ok, path}} ->
         result =
           if snapshot_referenced?(refs, ref),
             do: {:error, :snapshot_referenced},
             else: File.rm(path)

         {ref, result}
       end)}
    end
  end

  @doc "Remove every filesystem artifact owned by the supplied conversations."
  @spec delete_items([String.t()]) :: :ok | {:error, term()}
  def delete_items(conversation_ids) when is_list(conversation_ids) do
    root = root()

    with_root_lock(root, fn ->
      case File.lstat(root) do
        {:error, :enoent} ->
          :ok

        {:ok, %{type: :directory}} ->
          case validate_existing_directory(items_root(root)) do
            :ok ->
              failures =
                conversation_ids
                |> Enum.uniq()
                |> Enum.flat_map(&delete_item(root, &1))

              if failures == [], do: :ok, else: {:error, failures}

            {:error, :enoent} ->
              :ok

            {:error, _reason} = error ->
              error
          end

        {:ok, _stat} ->
          {:error, :invalid_artifact_root}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @doc "Delete expired tool-result spills and enforce the configured byte budget."
  @spec prune_tool_results(keyword()) :: cleanup_result()
  def prune_tool_results(opts \\ []) do
    root = Keyword.get(opts, :root, root())

    case with_root_lock(root, fn -> do_prune_tool_results(root, opts) end) do
      {:error, _reason} -> %{empty_cleanup_result() | failed: 1}
      result -> result
    end
  end

  @doc """
  Prune stale temporary files. Final snapshots are retained unless the caller sets
  `:no_pending_snapshot_publishers` to true after establishing that no pending
  publisher can later append any existing reference. Even then, only unreferenced,
  inactive snapshots exceeding the retention or capacity limits are removed.
  """
  @spec prune_change_snapshots(keyword()) :: cleanup_result()
  def prune_change_snapshots(opts \\ []) do
    root = Keyword.get(opts, :root, root())

    case with_root_lock(root, fn ->
           if Keyword.get(opts, :no_pending_snapshot_publishers, false) == true do
             with_snapshot_scan_lock(fn ->
               with {:ok, refs} <- durable_snapshot_refs() do
                 do_prune_change_snapshots(root, opts, refs)
               end
             end)
           else
             do_prune_change_snapshots(root, opts, [])
           end
         end) do
      {:error, _reason} -> %{empty_cleanup_result() | failed: 1}
      result -> result
    end
  end

  defp do_prune_change_snapshots(root, opts, refs) do
    with {:ok, files} <- snapshot_files(root) do
      now = Keyword.get(opts, :now, System.os_time(:second))
      expiry = now - max(Keyword.get(opts, :retention_seconds, 30 * 24 * 60 * 60), 0)
      temporary_expiry = now - max(Keyword.get(opts, :temporary_retention_seconds, 60 * 60), 0)
      capacity_cutoff = now - max(Keyword.get(opts, :min_retention_seconds, 24 * 60 * 60), 0)
      max_bytes = max(Keyword.get(opts, :max_bytes, 512 * 1024 * 1024), 0)
      protected_ids = MapSet.new(Keyword.get(opts, :protected_conversation_ids, []))

      eligible? = fn file ->
        not MapSet.member?(protected_ids, file.conversation_id) and
          not snapshot_runtime_active?(file.conversation_id) and
          (file.kind == :temporary or
             (Keyword.get(opts, :no_pending_snapshot_publishers, false) == true and
                not snapshot_referenced?(refs, file.ref)))
      end

      {remaining, result} =
        Enum.reduce(files, {[], empty_cleanup_result()}, fn file, {retained, result} ->
          cutoff = if file.kind == :temporary, do: temporary_expiry, else: expiry

          if file.mtime < cutoff and eligible?.(file) do
            remove_file(file, retained, result)
          else
            {[file | retained], result}
          end
        end)

      total = Enum.reduce(remaining, 0, &(&1.size + &2))

      {bytes, result} =
        remaining
        |> Enum.sort_by(&{&1.mtime, &1.path})
        |> Enum.reduce({total, result}, fn file, {bytes, result} ->
          if bytes > max_bytes and file.mtime < capacity_cutoff and eligible?.(file) do
            case File.rm(file.path) do
              :ok -> {bytes - file.size, deleted(result, file.size)}
              {:error, _reason} -> {bytes, failed(result)}
            end
          else
            {bytes, result}
          end
        end)

      %{result | retained_bytes: bytes}
    end
  end

  defp do_prune_tool_results(root, opts) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    retention_seconds = Keyword.get(opts, :retention_seconds, 30 * 24 * 60 * 60)
    temporary_retention_seconds = Keyword.get(opts, :temporary_retention_seconds, 60 * 60)
    max_bytes = Keyword.get(opts, :max_bytes, 512 * 1024 * 1024)
    min_retention_seconds = Keyword.get(opts, :min_retention_seconds, 24 * 60 * 60)
    protected_ids = MapSet.new(Keyword.get(opts, :protected_conversation_ids, []))
    protect_active? = Keyword.get(opts, :protect_active?, true)

    files = tool_result_files(root)
    expiry_cutoff = now - max(retention_seconds, 0)
    temporary_cutoff = now - max(temporary_retention_seconds, 0)

    {after_expiry, result} =
      Enum.reduce(files, {[], empty_cleanup_result()}, fn file, {retained, result} ->
        expired? =
          case file.kind do
            :spill -> file.mtime < expiry_cutoff
            :temporary -> file.mtime < temporary_cutoff
          end

        if expired? and not protected?(file.conversation_id, protected_ids, protect_active?) do
          remove_file(file, retained, result)
        else
          {[file | retained], result}
        end
      end)

    remaining = Enum.reverse(after_expiry)
    total = Enum.reduce(remaining, 0, &(&1.size + &2))
    capacity_cutoff = now - max(min_retention_seconds, 0)

    {retained_bytes, result} =
      remaining
      |> Enum.sort_by(&{&1.mtime, &1.path})
      |> Enum.reduce({total, result}, fn file, {bytes, result} ->
        removable? =
          bytes > max(max_bytes, 0) and file.mtime < capacity_cutoff and
            not protected?(file.conversation_id, protected_ids, protect_active?)

        if removable? do
          case File.rm(file.path) do
            :ok -> {bytes - file.size, deleted(result, file.size)}
            {:error, _reason} -> {bytes, failed(result)}
          end
        else
          {bytes, result}
        end
      end)

    %{result | retained_bytes: retained_bytes}
  end

  defp remove_file(file, retained, result) do
    case File.rm(file.path) do
      :ok -> {retained, deleted(result, file.size)}
      {:error, _reason} -> {[file | retained], failed(result)}
    end
  end

  defp validate_snapshot_ids(conversation_id, change_id) do
    if safe_id?(conversation_id) and safe_id?(change_id),
      do: :ok,
      else: {:error, :invalid_snapshot_id}
  end

  defp snapshot_root(root, conversation_id),
    do: Path.join(item_root(root, conversation_id), "change-snapshots")

  defp snapshot_path(root, conversation_id, change_id),
    do: Path.join(snapshot_root(root, conversation_id), change_id <> ".json")

  defp snapshot_ref(conversation_id, change_id),
    do:
      "change_snapshot:" <>
        Base.url_encode64(conversation_id <> <<0>> <> change_id, padding: false)

  defp ensure_snapshot_directories(root, conversation_id) do
    with :ok <- ensure_private_root(root),
         :ok <- ensure_private_directory(items_root(root), root),
         :ok <- ensure_private_directory(item_root(root, conversation_id), items_root(root)),
         :ok <-
           ensure_private_directory(
             snapshot_root(root, conversation_id),
             item_root(root, conversation_id)
           ) do
      :ok
    end
  end

  defp existing_snapshot_path(root, conversation_id, change_id) do
    path = snapshot_path(root, conversation_id, change_id)

    with :ok <- validate_existing_directory(root),
         :ok <- validate_existing_directory(items_root(root)),
         :ok <- validate_existing_directory(item_root(root, conversation_id)),
         :ok <- validate_existing_directory(snapshot_root(root, conversation_id)),
         :ok <- PathValidator.validate_under_root(path, snapshot_root(root, conversation_id)),
         {:ok, %{type: :regular}} <- File.lstat(path) do
      {:ok, path}
    else
      {:ok, _} -> {:error, :invalid_artifact_type}
      {:error, _} = error -> error
    end
  end

  defp publish_snapshot(path, content) do
    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with :ok <- write_private(temporary, content) do
      result = :file.make_link(String.to_charlist(temporary), String.to_charlist(path))
      _ = File.rm(temporary)
      result
    end
  end

  # Hold SQLite's writer reservation through the scan and file removal. No retry:
  # filesystem deletions cannot be rolled back or safely replayed.
  defp with_snapshot_scan_lock(fun) do
    if Handbean.Repo.in_transaction?() do
      {:error, :snapshot_scan_inside_transaction}
    else
      case Handbean.Repo.transaction(fun, mode: :immediate) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _ -> {:error, :snapshot_reference_scan_failed}
  catch
    :exit, _ -> {:error, :snapshot_reference_scan_failed}
  end

  # Scan every row, without visibility, lifecycle, workspace or pagination filters.
  # Decoding all JSON columns first ensures corrupted data fails closed.
  defp durable_snapshot_refs do
    with {:ok, %{rows: entries}} <-
           Handbean.Repo.query("""
           SELECT payload, conversation_id, entry_id, role, content_type, message_type,
                  direction, phase, status, run_id, tool_call_id, tool_status, content
           FROM conversation_entries
           """),
         {:ok, %{rows: sessions}} <-
           Handbean.Repo.query(
             "SELECT conversation_id, model, control_events, next_turn_messages, extension_state, snapshot FROM session_snapshots"
           ),
         {:ok, refs} <- collect_entry_refs(entries),
         {:ok, refs} <- collect_session_refs(sessions, refs) do
      {:ok, refs}
    end
  rescue
    _ -> {:error, :snapshot_reference_scan_failed}
  catch
    :exit, _ -> {:error, :snapshot_reference_scan_failed}
  end

  defp collect_entry_refs(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn [payload | fields], {:ok, refs} ->
      with {:ok, decoded} <- Handbean.JSON.decode(payload) do
        {:cont, {:ok, refs |> collect_refs(fields) |> collect_refs(decoded)}}
      else
        _ -> {:halt, {:error, :snapshot_reference_scan_failed}}
      end
    end)
  end

  defp collect_session_refs(rows, refs) do
    Enum.reduce_while(rows, {:ok, refs}, fn [conversation_id, model | columns], {:ok, refs} ->
      Enum.reduce_while(
        columns,
        {:ok, refs |> collect_refs(conversation_id) |> collect_refs(model)},
        fn
          nil, acc ->
            {:cont, acc}

          column, {:ok, acc} ->
            case Handbean.JSON.decode(column) do
              {:ok, value} -> {:cont, {:ok, collect_refs(acc, value)}}
              _ -> {:halt, {:error, :snapshot_reference_scan_failed}}
            end
        end
      )
      |> case do
        {:ok, _} = result -> {:cont, result}
        error -> {:halt, error}
      end
    end)
  end

  defp snapshot_referenced?(strings, ref), do: Enum.any?(strings, &String.contains?(&1, ref))

  defp collect_refs(refs, value) when is_binary(value) do
    if String.contains?(value, "change_snapshot:"), do: [value | refs], else: refs
  end

  defp collect_refs(refs, value) when is_map(value) do
    Enum.reduce(value, refs, fn {key, item}, acc ->
      acc |> collect_refs(key) |> collect_refs(item)
    end)
  end

  defp collect_refs(refs, value) when is_list(value),
    do: Enum.reduce(value, refs, &collect_refs(&2, &1))

  defp collect_refs(refs, _value), do: refs

  defp snapshot_files(root) do
    with :ok <- validate_existing_directory(root),
         :ok <- validate_existing_directory(items_root(root)),
         {:ok, conversations} <- File.ls(items_root(root)) do
      Enum.reduce_while(conversations, {:ok, []}, fn id, {:ok, files} ->
        case conversation_snapshot_files(root, id) do
          {:ok, more} -> {:cont, {:ok, more ++ files}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, :enoent} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp conversation_snapshot_files(root, conversation_id) do
    directory = snapshot_root(root, conversation_id)

    with true <- safe_id?(conversation_id),
         :ok <- validate_existing_directory(item_root(root, conversation_id)),
         :ok <- validate_existing_directory(directory),
         {:ok, names} <- File.ls(directory) do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, files} ->
        case snapshot_file(directory, conversation_id, name) do
          {:ok, nil} -> {:cont, {:ok, files}}
          {:ok, file} -> {:cont, {:ok, [file | files]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      false -> {:ok, []}
      {:error, :enoent} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp snapshot_file(directory, conversation_id, name) do
    case Regex.run(~r/\A([A-Za-z0-9_.:-]+)\.json(?:\.tmp-([A-Za-z0-9]+))?\z/, name) do
      [_, change_id | rest] when change_id not in [".", ".."] ->
        path = Path.join(directory, name)
        kind = if rest == [], do: :snapshot, else: :temporary

        with :ok <- PathValidator.validate_under_root(path, directory),
             {:ok, stat} <- File.lstat(path, time: :posix) do
          if stat.type == :regular do
            {:ok,
             %{
               path: path,
               size: stat.size,
               mtime: stat.mtime,
               kind: kind,
               conversation_id: conversation_id,
               ref: snapshot_ref(conversation_id, change_id)
             }}
          else
            {:ok, nil}
          end
        end

      _ ->
        {:ok, nil}
    end
  end

  # Registry unavailability cannot be treated as evidence of an idle run.
  defp snapshot_runtime_active?(conversation_id) do
    Enum.any?([Handbean.AgentRunSupervisorRegistry, Handbean.AgentRunRegistry], fn registry ->
      Registry.lookup(registry, conversation_id) != []
    end)
  rescue
    ArgumentError -> true
  catch
    :exit, _ -> true
  end

  defp artifact_root(context) do
    SafeMap.get_any(context, :conversation_artifact_root, "conversation_artifact_root") || root()
  end

  defp conversation_id(context),
    do: SafeMap.get_any(context, :conversation_id, "conversation_id")

  defp conversation_exists?(conversation_id, opts) do
    checker = Keyword.get(opts, :conversation_exists?, &Handbean.ConversationStore.exists?/1)
    checker.(conversation_id)
  end

  defp items_root(root), do: Path.join(root, "items")
  defp item_root(root, conversation_id), do: Path.join([items_root(root), conversation_id])

  defp tool_results_root(root, conversation_id),
    do: Path.join([item_root(root, conversation_id), "tool-results"])

  defp tool_result_path(root, conversation_id, filename),
    do: Path.join(tool_results_root(root, conversation_id), filename)

  defp spill_filename(content) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    @spill_prefix <> hash <> @spill_suffix
  end

  defp validate_spill_filename(
         <<@spill_prefix, hash::binary-size(@hash_bytes * 2), @spill_suffix>>
       ) do
    if String.match?(hash, ~r/\A[0-9a-f]+\z/), do: :ok, else: {:error, :invalid_artifact_ref}
  end

  defp validate_spill_filename(_filename), do: {:error, :invalid_artifact_ref}

  defp validate_temporary_filename(filename) do
    case String.split(filename, ".") do
      [spill, "txt", nonce, "tmp"] when byte_size(nonce) == 16 ->
        with :ok <- validate_spill_filename(spill <> ".txt"),
             true <- String.match?(nonce, ~r/\A[0-9a-f]+\z/) do
          :ok
        else
          _ -> {:error, :invalid_artifact_ref}
        end

      _ ->
        {:error, :invalid_artifact_ref}
    end
  end

  defp validate_owned_path(root, conversation_id, filename) do
    path = tool_result_path(root, conversation_id, filename)

    with :ok <-
           PathValidator.validate_under_root(item_root(root, conversation_id), items_root(root)),
         :ok <- PathValidator.validate_under_root(path, tool_results_root(root, conversation_id)),
         true <- Path.expand(item_root(root, conversation_id)) != Path.expand(items_root(root)),
         true <- Path.expand(item_root(root, conversation_id)) != Path.expand(root) do
      :ok
    else
      false -> {:error, :invalid_conversation_id}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_private_directories(root, conversation_id) do
    with :ok <- ensure_private_root(root),
         :ok <- ensure_private_directory(items_root(root), root),
         :ok <- ensure_private_directory(item_root(root, conversation_id), items_root(root)),
         :ok <-
           ensure_private_directory(
             tool_results_root(root, conversation_id),
             item_root(root, conversation_id)
           ) do
      :ok
    end
  end

  defp ensure_private_root(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> File.chmod(root, 0o700)
      {:ok, _stat} -> {:error, :invalid_artifact_root}
      {:error, :enoent} -> create_private_root(root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_private_root(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- validate_existing_directory(root),
         :ok <- File.chmod(root, 0o700) do
      :ok
    end
  end

  defp ensure_private_directory(path, parent) do
    with :ok <- PathValidator.validate_under_root(path, parent) do
      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          File.chmod(path, 0o700)

        {:ok, _stat} ->
          {:error, :invalid_artifact_directory}

        {:error, :enoent} ->
          with :ok <- validate_existing_directory(parent),
               :ok <- File.mkdir(path),
               :ok <- File.chmod(path, 0o700) do
            :ok
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_existing_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :invalid_artifact_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_content_addressed(path, content) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, ^content} -> File.touch(path)
          {:ok, _other} -> {:error, :hash_collision}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _stat} ->
        {:error, :invalid_artifact_type}

      {:error, :enoent} ->
        publish_content_addressed(path, content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_content_addressed(path, content) do
    nonce = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    temporary = path <> ".#{nonce}.tmp"

    case write_private(temporary, content) do
      :ok ->
        result = link_content(temporary, path, content)
        _ = File.rm(temporary)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_private(path, content) do
    case File.open(path, [:write, :binary, :exclusive, :sync], &IO.binwrite(&1, content)) do
      {:ok, :ok} ->
        case File.chmod(path, 0o600) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(path)
            {:error, reason}
        end

      {:ok, {:error, reason}} ->
        _ = File.rm(path)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_content(temporary, path, content) do
    case :file.make_link(String.to_charlist(temporary), String.to_charlist(path)) do
      :ok -> :ok
      {:error, :eexist} -> persist_content_addressed(path, content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_item(root, conversation_id) do
    cond do
      not safe_id?(conversation_id) ->
        [{to_string(conversation_id), :invalid_conversation_id}]

      not File.exists?(root) ->
        []

      true ->
        path = item_root(root, conversation_id)

        with :ok <- PathValidator.validate_under_root(path, items_root(root)),
             true <- Path.expand(path) != Path.expand(items_root(root)),
             :ok <- validate_delete_target(path),
             {:ok, _paths} <- File.rm_rf(path) do
          []
        else
          false -> [{conversation_id, :invalid_conversation_id}]
          {:error, :enoent} -> []
          {:error, reason} -> [{conversation_id, reason}]
          {:error, reason, _path} -> [{conversation_id, reason}]
        end
    end
  end

  defp validate_delete_target(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :invalid_artifact_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_result_files(root) do
    with :ok <- validate_existing_directory(root),
         :ok <- validate_existing_directory(items_root(root)),
         {:ok, conversations} <- File.ls(items_root(root)) do
      Enum.flat_map(conversations, &conversation_tool_result_files(root, &1))
    else
      {:error, :enoent} -> []
      _ -> []
    end
  end

  defp conversation_tool_result_files(root, conversation_id) do
    directory = tool_results_root(root, conversation_id)

    with true <- safe_id?(conversation_id),
         :ok <- validate_existing_directory(item_root(root, conversation_id)),
         :ok <- validate_existing_directory(directory),
         {:ok, filenames} <- File.ls(directory) do
      Enum.flat_map(filenames, &tool_result_file(directory, conversation_id, &1))
    else
      _ -> []
    end
  end

  defp tool_result_file(directory, conversation_id, filename) do
    kind =
      cond do
        validate_spill_filename(filename) == :ok -> :spill
        validate_temporary_filename(filename) == :ok -> :temporary
        true -> nil
      end

    path = Path.join(directory, filename)

    with kind when kind in [:spill, :temporary] <- kind,
         :ok <- PathValidator.validate_under_root(path, directory),
         {:ok, %{type: :regular, size: size, mtime: mtime}} <- File.lstat(path, time: :posix) do
      [%{path: path, size: size, mtime: mtime, conversation_id: conversation_id, kind: kind}]
    else
      _ -> []
    end
  end

  defp protected?(conversation_id, protected_ids, protect_active?) do
    MapSet.member?(protected_ids, conversation_id) or
      (protect_active? and runtime_active?(conversation_id))
  end

  defp runtime_active?(conversation_id) do
    registry_has_key?(Handbean.AgentRunSupervisorRegistry, conversation_id) or
      registry_has_key?(Handbean.AgentRunRegistry, conversation_id)
  end

  defp registry_has_key?(registry, key) do
    Registry.lookup(registry, key) != []
  rescue
    ArgumentError -> false
  end

  defp safe_id?(id) when is_binary(id) and id not in [".", ".."],
    do: Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, id)

  defp safe_id?(_id), do: false

  defp with_root_lock(root, fun) when is_binary(root) and root != "" and is_function(fun, 0) do
    lock_root = PathValidator.resolve_symlink(root)
    lock = {{__MODULE__, lock_root}, self()}

    case :global.trans(lock, fun) do
      :aborted -> {:error, :artifact_lock_aborted}
      result -> result
    end
  end

  defp with_root_lock(_root, _fun), do: {:error, :invalid_artifact_root}

  defp empty_cleanup_result,
    do: %{deleted: 0, freed_bytes: 0, retained_bytes: 0, failed: 0}

  defp deleted(result, bytes) do
    result
    |> Map.update!(:deleted, &(&1 + 1))
    |> Map.update!(:freed_bytes, &(&1 + bytes))
  end

  defp failed(result), do: Map.update!(result, :failed, &(&1 + 1))
end
