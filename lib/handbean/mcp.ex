defmodule Handbean.MCP do
  @moduledoc "Owns independent MCP runtime sets for each workspace/configuration source."

  use GenServer

  alias Handbean.MCP.{Access, ConfigLoader, RuntimeSupervisor, ToolBridge}

  @bootstrap_timeout_ms 120_000
  @shutdown_timeout_ms 65_000

  def load_config(opts \\ []), do: ConfigLoader.load(opts)
  def start_runtime(opts \\ []), do: RuntimeSupervisor.start_runtime(opts)

  def bootstrap(opts \\ [], timeout_ms \\ @bootstrap_timeout_ms),
    do: GenServer.call(__MODULE__, {:bootstrap, opts}, timeout_ms)

  def teardown_previous(opts \\ []),
    do: GenServer.call(__MODULE__, {:teardown, opts}, @bootstrap_timeout_ms)

  def register_runtime_tools(pid, cfg), do: ToolBridge.register_server_tools(pid, cfg)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts),
    do: {:ok, %{scopes: %{}, flights: %{}, stale_flights: %{}, generation: 0}}

  @impl true
  def handle_call({:bootstrap, opts}, from, state) do
    opts = Keyword.put_new(opts, :user_config_path, Handbean.MCP.Settings.path())
    key = Access.scope(opts)
    config = Access.config(opts)

    case Map.get(state.flights, key) do
      nil ->
        previous = Map.get(state.scopes, key)

        if reusable?(previous, config) do
          {:reply, {:ok, previous}, state}
        else
          {:noreply, start_flight(state, key, config, opts, [from], [])}
        end

      flight ->
        flight = enqueue_waiter(flight, config, opts, from, state.generation)
        {:noreply, put_in(state.flights[key], flight)}
    end
  end

  def handle_call({:teardown, _opts}, _from, state) do
    Enum.each(state.scopes, fn {_key, result} -> retire(result) end)

    Handbean.Tool.Registry.list()
    |> Enum.filter(&String.starts_with?(&1, "mcp__"))
    |> Enum.each(&Handbean.Tool.Registry.unregister/1)

    stale_flights =
      Enum.reduce(state.flights, state.stale_flights, fn {_key, flight}, stale ->
        reply_waiters(flight.waiters, {:error, :teardown})
        Enum.each(flight.queued, &reply_waiters(&1.waiters, {:error, :teardown}))

        flight = %{flight | waiters: [], queued: []}
        if Process.alive?(flight.task.pid), do: Process.exit(flight.task.pid, :kill)
        Map.put(stale, flight.id, flight)
      end)

    {:reply, :ok,
     %{
       state
       | scopes: %{},
         flights: %{},
         stale_flights: stale_flights,
         generation: state.generation + 1
     }}
  end

  @impl true
  def handle_info({:mcp_candidate_started, flight_id, pid}, state) do
    {:noreply, track_candidate(state, flight_id, pid)}
  end

  def handle_info({:mcp_candidate_discard, flight_id, pid}, state) do
    schedule_shutdown(pid)
    {:noreply, forget_candidate(state, flight_id, pid)}
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case flight_by_ref(state, ref) do
      {:active, key, flight} ->
        Process.demonitor(ref, [:flush])
        {:noreply, complete_active_flight(state, key, flight, outcome)}

      {:stale, flight_id, flight} ->
        Process.demonitor(ref, [:flush])
        {:noreply, complete_stale_flight(state, flight_id, flight, outcome)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case flight_by_ref(state, ref) do
      {:active, key, flight} ->
        {:noreply, complete_active_flight(state, key, flight, {:error, reason})}

      {:stale, flight_id, flight} ->
        {:noreply, complete_stale_flight(state, flight_id, flight, {:error, reason})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_flight(state, key, config, opts, waiters, queued) do
    owner = self()
    flight_id = make_ref()

    task =
      Task.Supervisor.async_nolink(Handbean.AgentRunTaskSupervisor, fn ->
        bootstrap_scope(owner, flight_id, config)
      end)

    flight = %{
      id: flight_id,
      task: task,
      config: config,
      opts: opts,
      waiters: waiters,
      queued: queued,
      generation: state.generation,
      candidate_pids: MapSet.new()
    }

    put_in(state.flights[key], flight)
  end

  defp bootstrap_scope(owner, flight_id, config) do
    {:ok, start_servers(owner, flight_id, config)}
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp enqueue_waiter(flight, config, _opts, from, generation)
       when flight.generation == generation and flight.config == config and flight.queued == [] do
    %{flight | waiters: [from | flight.waiters]}
  end

  defp enqueue_waiter(flight, config, opts, from, generation) do
    request = %{config: config, opts: opts, waiters: [from], generation: generation}
    %{flight | queued: append_request(flight.queued, request)}
  end

  defp append_request([], request), do: [request]

  defp append_request(queued, request) do
    {last, leading} = List.pop_at(queued, -1)

    if last.config == request.config and last.generation == request.generation do
      leading ++ [%{last | waiters: request.waiters ++ last.waiters}]
    else
      queued ++ [request]
    end
  end

  defp flight_by_ref(state, ref) do
    case Enum.find(state.flights, fn {_key, flight} -> flight.task.ref == ref end) do
      {key, flight} ->
        {:active, key, flight}

      nil ->
        case Enum.find(state.stale_flights, fn {_id, flight} -> flight.task.ref == ref end) do
          {flight_id, flight} -> {:stale, flight_id, flight}
          nil -> nil
        end
    end
  end

  defp track_candidate(state, flight_id, pid) do
    case active_flight_by_id(state.flights, flight_id) do
      {key, flight} ->
        flight = %{flight | candidate_pids: MapSet.put(flight.candidate_pids, pid)}
        put_in(state.flights[key], flight)

      nil ->
        case Map.get(state.stale_flights, flight_id) do
          nil ->
            unless runtime_owned?(state, pid), do: schedule_shutdown(pid)
            state

          flight ->
            flight = %{flight | candidate_pids: MapSet.put(flight.candidate_pids, pid)}
            put_in(state.stale_flights[flight_id], flight)
        end
    end
  end

  defp forget_candidate(state, flight_id, pid) do
    case active_flight_by_id(state.flights, flight_id) do
      {key, flight} ->
        flight = %{flight | candidate_pids: MapSet.delete(flight.candidate_pids, pid)}
        put_in(state.flights[key], flight)

      nil ->
        case Map.get(state.stale_flights, flight_id) do
          nil ->
            state

          flight ->
            flight = %{flight | candidate_pids: MapSet.delete(flight.candidate_pids, pid)}
            put_in(state.stale_flights[flight_id], flight)
        end
    end
  end

  defp active_flight_by_id(flights, flight_id) do
    Enum.find(flights, fn {_key, flight} -> flight.id == flight_id end)
  end

  defp runtime_owned?(state, pid) do
    Enum.any?(state.scopes, fn {_key, result} -> pid in result.runtime_pids end)
  end

  defp complete_active_flight(state, key, flight, {:ok, candidate}) do
    state = %{state | flights: Map.delete(state.flights, key)}

    if flight.generation == state.generation do
      previous = Map.get(state.scopes, key)
      if previous, do: retire(previous)

      cleanup_unowned_candidates(flight, candidate)
      result = commit_candidate(candidate, flight.opts)
      reply_waiters(flight.waiters, {:ok, result})

      state =
        state
        |> then(&%{&1 | scopes: Map.delete(&1.scopes, key)})
        |> put_in([:scopes, key], result)

      start_next(state, key, result, flight.queued)
    else
      retire_candidate(flight, candidate)
      reply_waiters(flight.waiters, {:error, :teardown})
      start_next(state, key, Map.get(state.scopes, key), flight.queued)
    end
  end

  defp complete_active_flight(state, key, flight, {:error, reason}) do
    retire_candidate_pids(flight.candidate_pids)
    reply_waiters(flight.waiters, {:error, reason})

    state = %{state | flights: Map.delete(state.flights, key)}
    start_next(state, key, Map.get(state.scopes, key), flight.queued)
  end

  defp complete_active_flight(state, key, flight, unexpected) do
    complete_active_flight(
      state,
      key,
      flight,
      {:error, {:unexpected_bootstrap_result, unexpected}}
    )
  end

  defp complete_stale_flight(state, flight_id, flight, {:ok, candidate}) do
    retire_candidate(flight, candidate)
    %{state | stale_flights: Map.delete(state.stale_flights, flight_id)}
  end

  defp complete_stale_flight(state, flight_id, flight, _outcome) do
    retire_candidate_pids(flight.candidate_pids)
    %{state | stale_flights: Map.delete(state.stale_flights, flight_id)}
  end

  defp start_next(state, _key, _previous, []), do: state

  defp start_next(state, key, previous, [request | queued]) do
    if request.generation == state.generation do
      if reusable?(previous, request.config) do
        reply_waiters(request.waiters, {:ok, previous})
        state = put_in(state.scopes[key], previous)
        start_next(state, key, previous, queued)
      else
        start_flight(
          state,
          key,
          request.config,
          request.opts,
          request.waiters,
          queued
        )
      end
    else
      reply_waiters(request.waiters, {:error, :teardown})
      start_next(state, key, previous, queued)
    end
  end

  defp reply_waiters(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp reusable?(nil, _config), do: false

  defp reusable?(previous, config) do
    previous.config == config and previous.server_errors == [] and
      Enum.all?(previous.runtime_pids, &Process.alive?/1) and
      Enum.all?(previous.registered, &(Handbean.Tool.Registry.get(&1) != :error))
  end

  defp start_servers(owner, flight_id, config) do
    Enum.reduce(
      config.servers,
      %{config: config, servers: [], server_errors: []},
      fn {name, cfg}, acc ->
        case safe_start_runtime(cfg, owner, flight_id) do
          {:ok, pid} ->
            # `ServerRuntime.init/1` reports before `start_child/2` returns, closing the
            # task-kill window. This second report shares the flight task's sender with
            # the Task outcome, so the owner always observes tracking before commit.
            send(owner, {:mcp_candidate_started, flight_id, pid})

            case ToolBridge.discover_server_tools(pid) do
              {:ok, tools} ->
                server = %{name: name, config: cfg, pid: pid, tools: tools}
                %{acc | servers: [server | acc.servers]}

              {:error, reason} ->
                send(owner, {:mcp_candidate_discard, flight_id, pid})
                add_server_error(acc, name, connection_error(reason, "Tool discovery failed"))
            end

          {:error, reason} ->
            add_server_error(acc, name, connection_error(reason, "Connection failed"))
        end
      end
    )
  end

  defp safe_start_runtime(config, owner, flight_id) do
    start_runtime(server_config: config, candidate_owner: owner, candidate_id: flight_id)
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    :exit, reason -> {:error, reason}
  end

  defp commit_candidate(candidate, opts) do
    Enum.reduce(
      Enum.reverse(candidate.servers),
      %{
        config: candidate.config,
        registered: [],
        servers: %{},
        runtime_pids: [],
        server_errors: candidate.server_errors
      },
      fn server, acc ->
        case register_candidate(server, opts) do
          {:ok, registered} ->
            %{
              acc
              | registered: acc.registered ++ registered,
                servers: Map.put(acc.servers, server.name, Map.take(server, [:pid, :config])),
                runtime_pids: [server.pid | acc.runtime_pids]
            }

          {:error, _reason} ->
            schedule_shutdown(server.pid)
            add_server_error(acc, server.name, "Tool registration failed")
        end
      end
    )
  end

  defp register_candidate(server, opts) do
    ToolBridge.register_discovered_tools(server.pid, server.config, server.tools, opts)
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    :exit, reason -> {:error, reason}
  end

  defp connection_error(reason, _fallback)
       when reason in [
              :authorization_required,
              :oauth_scope_required,
              :oauth_configuration_changed,
              "MCP OAuth authorization required. Connect this server in Plugins settings."
            ],
       do: "MCP authorization required. Authorize or reconnect this server in plugin settings."

  defp connection_error(_reason, fallback), do: fallback

  defp add_server_error(result, name, error) do
    %{result | server_errors: [%{server: name, error: error} | result.server_errors]}
  end

  defp cleanup_unowned_candidates(flight, candidate) do
    owned = MapSet.new(candidate.servers, & &1.pid)
    flight.candidate_pids |> MapSet.difference(owned) |> retire_candidate_pids()
  end

  defp retire_candidate(flight, candidate) do
    candidate_pids = MapSet.new(candidate.servers, & &1.pid)

    flight.candidate_pids
    |> MapSet.union(candidate_pids)
    |> retire_candidate_pids()
  end

  defp retire_candidate_pids(pids), do: Enum.each(pids, &schedule_shutdown/1)

  defp retire(result) do
    Enum.each(result.registered, &Handbean.Tool.Registry.unregister/1)
    Enum.each(result.runtime_pids, &schedule_shutdown/1)
  end

  defp schedule_shutdown(pid) when is_pid(pid) do
    case Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
           bounded_shutdown(pid)
         end) do
      {:ok, _task_pid} -> :ok
      {:error, _reason} -> if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end
  end

  defp bounded_shutdown(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, @shutdown_timeout_ms)
  catch
    :exit, _reason -> if Process.alive?(pid), do: Process.exit(pid, :kill)
  end
end
