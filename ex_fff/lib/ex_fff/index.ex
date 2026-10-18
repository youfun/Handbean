defmodule ExFff.Index do
  @moduledoc """
  GenServer that maintains the ETS-based file index.

  Manages three ETS tables per index instance:
  - Trigrams — trigram → path (:duplicate_bag)
  - Files — path → %{mtime, size} (:set)
  - Frecency — {score, path} → touched_at (:ordered_set; legacy value `true`)

  ## Public API

  - `start_link/1` — start the GenServer (async index build)
  - `ensure_started/1` — start or retrieve index for root_path (multi-workspace aware)
  - `search/3` — search for files by query
  - `touch/2` — update frecency after tool access
  - `refresh/1` — full re-scan
  - `get_root/1` — retrieve current workspace root
  - `set_root/2` — switch workspace root and trigger re-index
  - `await_index/2` — wait until indexing is complete
  """

  use GenServer

  require Logger

  defstruct root_path: nil,
            config: nil,
            frecency_ref: nil,
            trigram_ref: nil,
            files_ref: nil,
            git_ref: nil,
            frecency_path: nil,
            persist_timer: nil,
            indexed_count: 0,
            status: :indexing,
            task: nil,
            generation: 0,
            pending_searches: [],
            index_started_at: nil,
            last_indexed_at: nil,
            idle_timeout_ms: nil,
            idle_timer: nil,
            idle_token: nil

  @typedoc false
  @type state :: %__MODULE__{
          root_path: String.t() | nil,
          config: ExFff.Config.t() | nil,
          frecency_ref: :ets.tid() | atom() | nil,
          trigram_ref: :ets.tid() | atom() | nil,
          files_ref: :ets.tid() | atom() | nil,
          git_ref: :ets.tid() | atom() | nil,
          frecency_path: String.t() | nil,
          persist_timer: reference() | nil,
          indexed_count: non_neg_integer(),
          status: :indexing | :ready | :failed,
          task: Task.t() | nil,
          generation: non_neg_integer(),
          pending_searches: list(),
          index_started_at: integer() | nil,
          last_indexed_at: integer() | nil,
          idle_timeout_ms: pos_integer() | :infinity,
          idle_timer: reference() | nil,
          idle_token: reference() | nil
        }

  # ── Public API ──

  def child_spec(opts) do
    name = opts[:name] || __MODULE__

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc """
  Start the Index GenServer.

  Options:
  - `:root_path` — project root to scan (required)
  - `:max_files` — max files to index (default 100_001)
  - `:ignore_patterns` — additional regex patterns to ignore
  - `:name` — GenServer name (default `__MODULE__`)

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ensure an Index GenServer is started for a given root path.

  Supports multi-workspace environments. If an index for the specified root path
  is already running, returns its PID. Otherwise starts a new instance under
  `ExFff.IndexSupervisor` (or linked directly if supervisor is unavailable).
  """
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, String.t()}
  def ensure_started(root_path, opts \\ []) when is_binary(root_path) do
    expanded = Path.expand(root_path)

    case lookup_index(expanded) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        start_index_for_root(expanded, opts)
    end
  end

  @doc """
  Search for files matching the query.

  Options:
  - `:limit` — max results to return
  - `:await` — `true` waits for the initial index build; a non-negative integer
    waits at most that many ms, then returns the partial results with
    `status: :indexing` (default: false)
  - `:timeout` — call timeout in ms (default 5000); keep it above an integer `:await`

  Returns the currently indexed results immediately by default. The result's
  `:status` is `:indexing` until the background scan completes.
  """
  @spec search(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def search(pid \\ __MODULE__, query, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.call(pid, {:search, query, opts}, timeout)
  end

  @doc """
  Touch a file path to boost its frecency score.

  Call after a tool successfully operates on a file.
  """
  @spec touch(GenServer.server(), String.t()) :: :ok | {:error, String.t()}
  def touch(pid \\ __MODULE__, path) do
    GenServer.cast(pid, {:touch, path})
  end

  @doc "Return the indexed file inventory in stable lexical pages."
  @spec files(GenServer.server(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def files(pid \\ __MODULE__, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.call(pid, {:files, opts}, timeout)
  end

  @doc "Apply incremental filesystem changes to the inventory."
  @spec update_paths(GenServer.server(), [String.t()]) :: :ok
  def update_paths(pid \\ __MODULE__, paths) when is_list(paths) do
    GenServer.cast(pid, {:update_paths, paths})
  end

  @doc "Replace Git status annotations used by path ranking."
  @spec set_git_status(GenServer.server(), map() | [{String.t(), atom()}]) :: :ok
  def set_git_status(pid \\ __MODULE__, entries) do
    GenServer.cast(pid, {:set_git_status, entries})
  end

  @doc """
  Trigger a full index refresh (rescan all files).
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(pid \\ __MODULE__) do
    GenServer.cast(pid, :refresh)
  end

  @doc """
  Get the configured root path of the index.
  """
  @spec get_root(GenServer.server()) :: {:ok, String.t()}
  def get_root(pid \\ __MODULE__) do
    GenServer.call(pid, :get_root)
  end

  @doc """
  Update the root path and trigger a re-index.
  """
  @spec set_root(GenServer.server(), String.t()) :: :ok | {:error, String.t()}
  def set_root(pid \\ __MODULE__, root_path) do
    GenServer.call(pid, {:set_root, root_path})
  end

  @doc """
  Wait until the index build has completed.
  """
  @spec await_index(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_index(pid \\ __MODULE__, timeout \\ 5000) do
    GenServer.call(pid, :await_index, timeout)
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    root_path = Keyword.fetch!(opts, :root_path)

    if !File.dir?(root_path) do
      {:stop, "root_path is not a directory: #{root_path}"}
    else
      config =
        ExFff.Config.new(
          root_path: root_path,
          max_files: Keyword.get(opts, :max_files, 100_001),
          ignore_patterns:
            Keyword.get(opts, :ignore_patterns, ExFff.Config.new().ignore_patterns),
          path_filter: Keyword.get(opts, :path_filter)
        )

      # Create isolated ETS tables per index instance
      trigram_tab =
        :ets.new(:ex_fff_trigrams, [:duplicate_bag, :public, {:read_concurrency, true}])

      files_tab = :ets.new(:ex_fff_files, [:ordered_set, :public, {:read_concurrency, true}])
      git_tab = :ets.new(:ex_fff_git_status, [:set, :public, {:read_concurrency, true}])

      frecency_tab =
        :ets.new(:ex_fff_frecency, [:ordered_set, :public, {:read_concurrency, true}])

      frecency_path = frecency_path(root_path, Keyword.get(opts, :frecency_dir))
      load_frecency(frecency_tab, frecency_path)

      state = %__MODULE__{
        root_path: root_path,
        config: config,
        trigram_ref: trigram_tab,
        files_ref: files_tab,
        git_ref: git_tab,
        frecency_path: frecency_path,
        frecency_ref: frecency_tab,
        indexed_count: 0,
        status: :indexing,
        task: nil,
        generation: 0,
        pending_searches: [],
        index_started_at: nil,
        last_indexed_at: nil,
        idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 30 * 60 * 1_000),
        idle_timer: nil,
        idle_token: nil
      }

      state = state |> start_indexing() |> mark_used()

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:search, query_string, opts}, from, state) do
    cond do
      state.status == :failed ->
        {:reply, {:error, "Indexing failed for #{state.root_path}"}, state}

      state.status == :indexing and await?(opts) ->
        pending = {from, query_string, opts, state.generation}
        schedule_await_timeout(from, Keyword.get(opts, :await))
        {:noreply, %{state | pending_searches: [pending | state.pending_searches]}}

      true ->
        {:reply, do_search(query_string, opts, state), mark_used(state)}
    end
  end

  @impl true
  def handle_call({:files, opts}, _from, state) do
    {:reply, {:ok, list_files(opts, state)}, mark_used(state)}
  end

  @impl true
  def handle_call(:await_index, from, state) do
    case state.status do
      :ready ->
        {:reply, :ok, state}

      :failed ->
        {:reply, {:error, "Indexing failed for #{state.root_path}"}, state}

      :indexing ->
        pending = {from, :await_index, [], state.generation}
        {:noreply, %{state | pending_searches: [pending | state.pending_searches]}}
    end
  end

  @impl true
  def handle_call(:get_root, _from, state) do
    {:reply, {:ok, state.root_path}, state}
  end

  @impl true
  def handle_call({:set_root, root_path}, _from, state) do
    expanded = Path.expand(root_path)

    if !File.dir?(expanded) do
      {:reply, {:error, "root_path is not a directory: #{root_path}"}, state}
    else
      state = cancel_indexing(state, {:error, "index root changed"})
      persist_frecency(state.frecency_ref, state.frecency_path)
      clear_inventory(state)
      :ets.delete_all_objects(state.frecency_ref)
      :ets.delete_all_objects(state.git_ref)

      config = %{state.config | root_path: expanded}
      path = frecency_path(expanded, Path.dirname(state.frecency_path))
      load_frecency(state.frecency_ref, path)

      new_state = %{
        state
        | root_path: expanded,
          config: config,
          frecency_path: path,
          indexed_count: 0,
          status: :indexing,
          task: nil
      }

      {:reply, :ok, start_indexing(new_state)}
    end
  end

  @impl true
  def handle_call(:get_counts, _from, state) do
    files_size = if state.files_ref, do: :ets.info(state.files_ref, :size) || 0, else: 0
    trigrams_size = if state.trigram_ref, do: :ets.info(state.trigram_ref, :size) || 0, else: 0
    frecency_size = if state.frecency_ref, do: :ets.info(state.frecency_ref, :size) || 0, else: 0

    counts = %{
      files: files_size,
      trigrams: trigrams_size,
      frecency: frecency_size
    }

    {:reply, {:ok, counts}, state}
  end

  @impl true
  def handle_cast({:touch, path}, state) do
    relative = relative_path(path, state.root_path)

    if is_binary(relative) and :ets.member(state.files_ref, relative) do
      objects = :ets.match_object(state.frecency_ref, {{:_, relative}, :_})

      now = System.system_time(:second)

      {score, touched_at} =
        case objects do
          [] -> {0.0, nil}
          [{{s, _p}, meta} | _] -> {s * 1.0, frecency_timestamp(meta)}
        end

      elapsed = if is_integer(touched_at), do: max(now - touched_at, 0), else: 0
      base = ExFff.Matcher.normalize_stored_frecency(score)
      new_score = ExFff.Matcher.compute_frecency(base, elapsed)

      :ets.match_delete(state.frecency_ref, {{:_, relative}, :_})
      :ets.insert(state.frecency_ref, {{new_score, relative}, now})
    end

    {:noreply, state |> schedule_frecency_persist() |> mark_used()}
  end

  def handle_cast({:update_paths, paths}, state) do
    Enum.each(paths, &update_path(&1, state))
    count = :ets.info(state.files_ref, :size) || 0
    {:noreply, %{state | indexed_count: count}}
  end

  def handle_cast({:set_git_status, entries}, state) do
    :ets.delete_all_objects(state.git_ref)

    rows =
      entries
      |> Enum.map(fn {path, status} -> {relative_path(path, state.root_path), status} end)
      |> Enum.filter(fn {path, status} -> is_binary(path) and not is_nil(status) end)

    if rows != [], do: :ets.insert(state.git_ref, rows)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, start_indexing(state)}
  end

  @impl true
  def handle_info(:build_index, state) do
    {:noreply, start_indexing(state)}
  end

  def handle_info(:persist_frecency, state) do
    persist_frecency(state.frecency_ref, state.frecency_path)
    {:noreply, %{state | persist_timer: nil}}
  end

  def handle_info({:idle_timeout, token}, %{idle_token: token, status: status} = state) do
    if status == :indexing do
      {:noreply, mark_used(%{state | idle_timer: nil, idle_token: nil})}
    else
      {:stop, :normal, %{state | idle_timer: nil, idle_token: nil}}
    end
  end

  def handle_info({:idle_timeout, _token}, state), do: {:noreply, state}

  def handle_info({:await_timeout, from}, state) do
    case Enum.split_with(state.pending_searches, &match?({^from, _, _, _}, &1)) do
      {[{^from, query_string, opts, _generation}], rest} ->
        GenServer.reply(from, do_search(query_string, opts, state))
        {:noreply, mark_used(%{state | pending_searches: rest})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:index_batch, generation, files_entries, trig_entries},
        %{generation: generation, status: :indexing} = state
      ) do
    if files_entries != [], do: :ets.insert(state.files_ref, files_entries)
    if trig_entries != [], do: :ets.insert(state.trigram_ref, trig_entries)

    {:noreply, %{state | indexed_count: :ets.info(state.files_ref, :size) || 0}}
  end

  def handle_info({:index_batch, _generation, _files_entries, _trig_entries}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {ref, {:ok, generation, count}},
        %{task: %Task{ref: ref}, generation: generation} = state
      ) do
    Process.demonitor(ref, [:flush])

    prune_frecency(state.frecency_ref, state.files_ref)

    elapsed =
      if state.index_started_at do
        System.monotonic_time(:millisecond) - state.index_started_at
      else
        0
      end

    Logger.info("[ExFff.Index] Indexed #{count} files in #{elapsed}ms for #{state.root_path}")
    emit_index_telemetry(state.root_path, elapsed, count, :ready)

    new_state = %{
      state
      | indexed_count: count,
        status: :ready,
        task: nil,
        index_started_at: nil,
        last_indexed_at: System.system_time(:second)
    }

    {:noreply, flush_pending_searches(new_state, generation)}
  end

  def handle_info({:index_failed, generation, reason}, state) do
    fail_indexing(state, generation, reason)
  end

  def handle_info({ref, {:error, generation, reason}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    fail_indexing(state, generation, reason)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # A matching result message is handled above and demonitors with :flush.
    # Reaching here means the task died without a usable result.
    fail_indexing(state, state.generation, reason)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{task: %Task{pid: pid}} = state) do
    fail_indexing(state, state.generation, reason)
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.task do
      Task.shutdown(state.task, :brutal_kill)
    end

    persist_frecency(state.frecency_ref, state.frecency_path)

    :ok
  end

  # ── Internal Functions ──

  defp start_indexing(state) do
    state = if state.task, do: cancel_indexing(state, {:error, "index restarted"}), else: state
    clear_inventory(state)
    generation = state.generation + 1
    root = state.root_path
    config = state.config

    Logger.info("[ExFff.Index] Building file index for #{root}...")
    started_at = System.monotonic_time(:millisecond)
    owner = self()

    task =
      Task.async(fn ->
        {:ok, count} =
          ExFff.Scanner.scan_and_prepare(root, config, fn files_entries, trig_entries ->
            send(owner, {:index_batch, generation, files_entries, trig_entries})
          end)

        {:ok, generation, count}
      end)

    %{
      state
      | task: task,
        generation: generation,
        status: :indexing,
        indexed_count: 0,
        index_started_at: started_at
    }
  end

  defp cancel_indexing(state, reply) do
    if state.task do
      Task.shutdown(state.task, :brutal_kill)
    end

    reply_pending(state.pending_searches, state.generation, reply)
    %{state | task: nil, pending_searches: []}
  end

  defp fail_indexing(state, generation, reason) do
    Logger.error("[ExFff.Index] Indexing task failed for #{state.root_path}: #{inspect(reason)}")

    if generation == state.generation do
      elapsed =
        if state.index_started_at,
          do: System.monotonic_time(:millisecond) - state.index_started_at,
          else: 0

      emit_index_telemetry(state.root_path, elapsed, state.indexed_count, :failed)

      reply_pending(
        state.pending_searches,
        generation,
        {:error, "Indexing failed: #{inspect(reason)}"}
      )

      {:stop, {:indexing_failed, reason},
       %{
         state
         | task: nil,
           status: :failed,
           pending_searches: [],
           index_started_at: nil
       }}
    else
      {:noreply, %{state | task: nil}}
    end
  end

  defp clear_inventory(state) do
    :ets.delete_all_objects(state.files_ref)
    :ets.delete_all_objects(state.trigram_ref)
  end

  defp await?(opts) do
    case Keyword.get(opts, :await, false) do
      true -> true
      ms when is_integer(ms) and ms >= 0 -> true
      _ -> false
    end
  end

  defp schedule_await_timeout(from, ms) when is_integer(ms) do
    Process.send_after(self(), {:await_timeout, from}, ms)
  end

  defp schedule_await_timeout(_from, _await), do: :ok

  defp reply_pending(pending, generation, reply) do
    for {from, _kind, _opts, pending_generation} <- pending,
        pending_generation == generation do
      GenServer.reply(from, reply)
    end
  end

  defp prune_frecency(frecency_ref, files_ref) do
    :ets.foldl(
      fn {{_score, path}, _value}, acc ->
        unless :ets.member(files_ref, path) do
          :ets.match_delete(frecency_ref, {{:_, path}, :_})
        end

        acc
      end,
      :ok,
      frecency_ref
    )
  end

  defp emit_index_telemetry(root, elapsed, count, status) do
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :execute, [
        [:ex_fff, :index, :build],
        %{duration_ms: elapsed, file_count: count},
        %{root: root, status: status}
      ])
    end
  end

  defp do_search(query_string, opts, state) do
    start_time = System.monotonic_time(:millisecond)
    parsed_query = ExFff.Query.parse(query_string)

    limit = Keyword.get(opts, :limit, parsed_query.limit)
    offset = decode_offset(Keyword.get(opts, :cursor))
    parsed_query = %{parsed_query | limit: max(state.indexed_count, max(limit + offset + 1, 1))}
    prefix = normalize_prefix(Keyword.get(opts, :path))
    excludes = opts |> Keyword.get(:exclude, []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

    matches =
      ExFff.Matcher.match(
        parsed_query,
        state.files_ref,
        state.trigram_ref,
        state.frecency_ref,
        state.git_ref
      )
      |> Enum.filter(&inventory_path?(&1.path, prefix, excludes, nil))

    page = matches |> Enum.drop(offset) |> Enum.take(limit + 1)
    results = Enum.take(page, limit)
    partial_match = partial_match(matches)

    next_cursor =
      if length(page) > length(results), do: encode_offset(offset + length(results)), else: nil

    duration_ms = System.monotonic_time(:millisecond) - start_time

    {:ok,
     %{
       paths: results,
       query: query_string,
       duration_ms: duration_ms,
       status: state.status,
       indexed_count: state.indexed_count,
       cursor: next_cursor,
       partial_match: partial_match
     }}
  end

  defp partial_match([%{partial?: true, matched_terms: matched, term_count: total} | _])
       when is_integer(matched) and is_integer(total) do
    %{matched: matched, total: total}
  end

  defp partial_match(_matches), do: nil

  defp encode_offset(offset), do: Base.url_encode64(Integer.to_string(offset), padding: false)

  defp decode_offset(nil), do: 0

  defp decode_offset(cursor) when is_binary(cursor) do
    with {:ok, value} <- Base.url_decode64(cursor, padding: false),
         {offset, ""} when offset >= 0 <- Integer.parse(value) do
      offset
    else
      _ -> 0
    end
  end

  defp decode_offset(_), do: 0

  defp list_files(opts, state) do
    prefix = normalize_prefix(Keyword.get(opts, :path))
    excludes = opts |> Keyword.get(:exclude, []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
    after_path = decode_cursor(Keyword.get(opts, :cursor))
    limit = opts |> Keyword.get(:limit, 1_000) |> max(1) |> min(10_000)

    matching =
      state.files_ref
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&inventory_path?(&1, prefix, excludes, after_path))

    page = Enum.take(matching, limit)
    more? = length(matching) > length(page)

    %{
      paths: page,
      cursor: if(more?, do: encode_cursor(List.last(page)), else: nil),
      status: state.status,
      indexed_count: state.indexed_count
    }
  end

  defp inventory_path?(path, prefix, excludes, after_path) do
    (prefix == "" or path == prefix or String.starts_with?(path, prefix <> "/")) and
      (is_nil(after_path) or path > after_path) and
      Enum.all?(excludes, &(not String.contains?(path, &1)))
  end

  defp normalize_prefix(nil), do: ""
  defp normalize_prefix("."), do: ""

  defp normalize_prefix(path) when is_binary(path),
    do: path |> String.trim("/") |> Path.expand("/") |> Path.relative_to("/")

  defp normalize_prefix(_), do: ""

  defp encode_cursor(path), do: Base.url_encode64(path, padding: false)

  defp decode_cursor(nil), do: nil

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, path} -> path
      :error -> nil
    end
  end

  defp decode_cursor(_), do: nil

  defp update_path(path, state) do
    case relative_path(path, state.root_path) do
      nil ->
        :ok

      relative ->
        remove_path(relative, state)

        case ExFff.Scanner.prepare_path(state.root_path, relative, state.config) do
          {:ok, file_entry, trigrams} ->
            make_room_for_incremental_file(state)
            :ets.insert(state.files_ref, file_entry)
            if trigrams != [], do: :ets.insert(state.trigram_ref, trigrams)

          :ignore ->
            :ok
        end
    end
  end

  defp make_room_for_incremental_file(state) do
    # Keep the hard memory cap, but prioritize the path that just changed so a
    # successful write is immediately discoverable even in a capped workspace.
    if :ets.info(state.files_ref, :size) >= state.config.max_files do
      case :ets.last(state.files_ref) do
        :"$end_of_table" -> :ok
        path -> remove_file(path, state)
      end
    end
  end

  defp remove_path(relative, state) do
    prefix = relative <> "/"
    if :ets.member(state.files_ref, relative), do: remove_file(relative, state)
    remove_descendants(:ets.next(state.files_ref, relative), prefix, state)
  end

  defp remove_descendants(:"$end_of_table", _prefix, _state), do: :ok

  defp remove_descendants(path, prefix, state) do
    if String.starts_with?(path, prefix) do
      next = :ets.next(state.files_ref, path)
      remove_file(path, state)
      remove_descendants(next, prefix, state)
    else
      :ok
    end
  end

  defp remove_file(path, state) do
    :ets.delete(state.files_ref, path)

    path
    |> String.downcase()
    |> ExFff.Matcher.tokenize()
    |> Enum.each(&:ets.delete_object(state.trigram_ref, {&1, path}))

    :ets.match_delete(state.frecency_ref, {{:_, path}, :_})
    :ets.delete(state.git_ref, path)
  end

  defp relative_path(path, root) when is_binary(path) do
    expanded =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, root)

    expanded_root = Path.expand(root)

    if expanded != expanded_root and String.starts_with?(expanded, expanded_root <> "/") do
      Path.relative_to(expanded, expanded_root)
    end
  end

  defp relative_path(_, _), do: nil

  defp schedule_frecency_persist(%{persist_timer: nil} = state) do
    %{state | persist_timer: Process.send_after(self(), :persist_frecency, 200)}
  end

  defp schedule_frecency_persist(state), do: state

  defp mark_used(%{idle_timeout_ms: :infinity} = state), do: state

  defp mark_used(state) do
    if is_reference(state.idle_timer), do: Process.cancel_timer(state.idle_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:idle_timeout, token}, state.idle_timeout_ms)
    %{state | idle_timer: timer, idle_token: token}
  end

  defp frecency_path(root, nil) do
    frecency_path(root, Path.join([System.user_home!(), ".handbean", "fff"]))
  end

  defp frecency_path(root, dir) do
    digest = :crypto.hash(:sha256, Path.expand(root)) |> Base.url_encode64(padding: false)
    Path.join(dir, digest <> ".term")
  end

  defp frecency_timestamp(ts) when is_integer(ts), do: ts
  defp frecency_timestamp(%{touched_at: ts}) when is_integer(ts), do: ts
  defp frecency_timestamp(_meta), do: nil

  defp load_frecency(table, path) do
    with {:ok, binary} <- File.read(path),
         entries when is_list(entries) <- :erlang.binary_to_term(binary, [:safe]) do
      entries
      |> Enum.filter(fn
        {score, rel, touched_at}
        when is_number(score) and is_binary(rel) and is_integer(touched_at) ->
          true

        {score, rel} when is_number(score) and is_binary(rel) ->
          true

        _ ->
          false
      end)
      |> Enum.each(fn
        {score, rel, touched_at} ->
          :ets.insert(table, {{score * 1.0, rel}, touched_at})

        {score, rel} ->
          normalized = ExFff.Matcher.normalize_stored_frecency(score)
          :ets.insert(table, {{normalized, rel}, System.system_time(:second)})
      end)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp persist_frecency(nil, _path), do: :ok

  defp persist_frecency(table, path) do
    entries =
      Enum.map(:ets.tab2list(table), fn
        {{score, rel}, touched_at} when is_integer(touched_at) -> {score, rel, touched_at}
        {{score, rel}, _meta} -> {score, rel}
      end)

    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(entries)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      _ -> File.rm(tmp)
    end
  rescue
    _ -> :ok
  end

  defp flush_pending_searches(state, generation) do
    {current, stale} =
      Enum.split_with(state.pending_searches, fn {_from, _kind, _opts, pending_generation} ->
        pending_generation == generation
      end)

    reply_pending(stale, generation - 1, {:error, "index restarted"})

    for item <- Enum.reverse(current) do
      case item do
        {from, :await_index, _opts, ^generation} ->
          GenServer.reply(from, :ok)

        {from, query_string, opts, ^generation} ->
          GenServer.reply(from, do_search(query_string, opts, state))
      end
    end

    %{state | pending_searches: []}
  end

  # ── Multi-Workspace Registry & Lookup ──

  defp lookup_index(root) do
    case Process.whereis(ExFff.Registry) do
      nil ->
        :not_found

      _reg ->
        case Registry.lookup(ExFff.Registry, root) do
          [{pid, _value}] ->
            if Process.alive?(pid), do: {:ok, pid}, else: :not_found

          [] ->
            :not_found
        end
    end
  end

  defp start_index_for_root(root, opts) do
    case Process.whereis(ExFff.IndexSupervisor) do
      nil ->
        case start_link(Keyword.merge(opts, root_path: root)) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, "Failed to start ExFff.Index: #{inspect(reason)}"}
        end

      _sup ->
        child_spec = {
          __MODULE__,
          Keyword.merge(opts,
            root_path: root,
            name: {:via, Registry, {ExFff.Registry, root}}
          )
        }

        case DynamicSupervisor.start_child(ExFff.IndexSupervisor, child_spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, "Failed to start ExFff.Index: #{inspect(reason)}"}
        end
    end
  end
end
