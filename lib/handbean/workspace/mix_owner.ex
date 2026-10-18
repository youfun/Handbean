defmodule Handbean.Workspace.MixOwner do
  @moduledoc """
  Single VM-wide owner for Mix project operations.

  `Mix.Project.in_project/4` and dependency builds change the process
  *and* the VM current working directory. Mix, Hex, and ExUnit are also
  shared. All project work is serialized here, globals are restored after
  return, crash, timeout, or cancel, and processes spawned by the managed
  worker are terminated before the owner is released. Work handed to a
  pre-existing process, external OS process, or remote node is outside this
  lifecycle. Directory layout is not isolation.
  """

  use GenServer

  @env_keys ~w(
    MIX_HOME
    HEX_HOME
    HEX_OFFLINE
    MIX_ENV
    MIX_BUILD_PATH
    MIX_DEPS_PATH
    MIX_OS_DEPS_COMPILE_PARTITION_COUNT
    MIX_OS_CONCURRENCY_LOCK
    MIX_QUIET
  )

  @type result :: {:ok, term()} | {:error, String.t(), map()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run((-> term()), keyword()) :: result()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    server = Keyword.get(opts, :server, __MODULE__)

    GenServer.call(server, {:run, fun, opts}, timeout + 5_000)
  end

  @spec cancel(atom() | pid()) :: :ok | {:error, String.t(), map()}
  def cancel(server \\ __MODULE__) do
    GenServer.call(server, :cancel, :infinity)
  end

  @doc "Cancel only work owned by this caller, waiting for global-state restoration."
  def cancel_for(caller, server \\ __MODULE__) when is_pid(caller) do
    GenServer.call(server, {:cancel_for, caller}, :infinity)
  end

  @spec busy?(atom() | pid()) :: boolean()
  def busy?(server \\ __MODULE__) do
    GenServer.call(server, :busy?)
  end

  @spec host_snapshot(atom() | pid()) :: Handbean.Workspace.MixCompat.t()
  def host_snapshot(server \\ __MODULE__) do
    GenServer.call(server, :host_snapshot)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       job: nil,
       restore_error: nil,
       supervisor: supervisor,
       host: Handbean.Workspace.MixCompat.snapshot(),
       workspace_roots: MapSet.new(),
       workspace_modules: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:run, _fun, _opts}, _from, %{restore_error: error} = state)
      when not is_nil(error), do: {:reply, error, state}

  def handle_call({:run, _fun, _opts}, _from, %{job: job} = state) when not is_nil(job) do
    {:reply, {:error, "another Mix project operation is running", %{busy: true}}, state}
  end

  def handle_call({:run, fun, opts}, {caller, _tag} = from, %{job: nil} = state) do
    if Process.alive?(caller) do
      start_job(fun, opts, from, state)
    else
      {:reply, {:error, "Mix caller has exited", %{cancelled: true}}, state}
    end
  end

  def handle_call({:cancel_for, caller}, from, %{job: %{from: {caller, _}}} = state),
    do: handle_call(:cancel, from, state)

  def handle_call({:cancel_for, _caller}, _from, state),
    do: {:reply, state.restore_error || :ok, state}

  def handle_call(:cancel, _from, %{job: nil} = state),
    do: {:reply, state.restore_error || :ok, state}

  def handle_call(:cancel, from, %{job: job} = state) do
    job =
      job
      |> Map.update!(:cancel_from, &[from | &1])
      |> begin_shutdown({:error, "Mix project operation cancelled", %{cancelled: true}})

    complete_or_continue(%{state | job: job})
  end

  def handle_call(:busy?, _from, state), do: {:reply, state.job != nil, state}

  def handle_call(:host_snapshot, _from, state), do: {:reply, state.host, state}

  defp start_job(fun, opts, {caller, _tag} = from, state) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    snapshot = snapshot()
    parent = self()
    project_path = opts[:project_path] && Path.expand(opts[:project_path])

    project_modules =
      if project_path,
        do: Handbean.Workspace.MixCompat.project_module_names(project_path),
        else: MapSet.new()

    host =
      Handbean.Workspace.MixCompat.refresh_loaded_modules(
        state.host,
        MapSet.to_list(state.workspace_roots),
        state.workspace_modules
      )

    {:ok, worker} =
      Task.Supervisor.start_child(state.supervisor, fn ->
        receive do: (:mix_owner_start -> :ok)
        send(parent, {:mix_owner_result, self(), invoke(fun)})
      end)

    worker_ref = Process.monitor(worker)
    :erlang.trace(worker, true, [:procs, :set_on_spawn, {:tracer, self()}])
    send(worker, :mix_owner_start)

    {:noreply,
     %{
       state
       | host: host,
         job: %{
           from: from,
           worker: worker,
           project_path: project_path,
           project_modules: project_modules,
           caller_ref: Process.monitor(caller),
           timer: Process.send_after(self(), {:mix_owner_timeout, worker}, timeout),
           snapshot: snapshot,
           managed: %{worker => worker_ref},
           outcome: nil,
           reply?: true,
           stopping?: false,
           cancel_from: []
         }
     }}
  end

  @impl true
  def handle_info({:mix_owner_result, worker, result}, %{job: %{worker: worker} = job} = state) do
    complete_or_continue(%{state | job: begin_shutdown(job, result, kill_worker?: false)})
  end

  def handle_info({:mix_owner_timeout, worker}, %{job: %{worker: worker} = job} = state) do
    job = begin_shutdown(job, {:error, "Mix project operation timed out", %{timed_out: true}})
    complete_or_continue(%{state | job: job})
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{job: job} = state) do
    if job.caller_ref == ref do
      job = job |> Map.put(:reply?, false) |> begin_shutdown(nil)
      complete_or_continue(%{state | job: job})
    else
      managed = remove_managed(job.managed, pid, ref)
      job = %{job | managed: managed}

      job =
        if pid == job.worker and not job.stopping? do
          begin_shutdown(
            job,
            {:error, "Mix project worker exited: #{inspect(reason)}", %{exit: inspect(reason)}},
            kill_worker?: false
          )
        else
          job
        end

      complete_or_continue(%{state | job: job})
    end
  end

  def handle_info({:trace, _parent, :spawn, child, _mfa}, %{job: job} = state) do
    if Map.has_key?(job.managed, child) do
      {:noreply, state}
    else
      ref = Process.monitor(child)
      if job.stopping?, do: Process.exit(child, :kill)
      {:noreply, %{state | job: %{job | managed: Map.put(job.managed, child, ref)}}}
    end
  end

  def handle_info({:mix_owner_result, _worker, _result}, state), do: {:noreply, state}
  def handle_info({:mix_owner_timeout, _worker}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:trace, _pid, _event, _detail}, state), do: {:noreply, state}
  def handle_info({:trace, _pid, _event, _detail, _extra}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{job: nil}), do: :ok

  def terminate(_reason, %{job: job}) do
    Enum.each(Map.keys(job.managed), &Process.exit(&1, :kill))
    :ok
  end

  defp invoke(fun) do
    try do
      {:ok, fun.()}
    rescue
      exception ->
        {:error, Exception.format(:error, exception, __STACKTRACE__),
         %{raised: true, exception: Exception.message(exception)}}
    catch
      :exit, reason ->
        {:error, "Mix project worker exited: #{inspect(reason)}", %{exit: inspect(reason)}}

      kind, reason ->
        {:error, Exception.format(kind, reason, []), %{caught: kind}}
    end
  end

  defp begin_shutdown(job, result, opts \\ [])

  defp begin_shutdown(%{stopping?: true} = job, _result, _opts), do: job

  defp begin_shutdown(job, result, opts) do
    kill_worker? = Keyword.get(opts, :kill_worker?, true)
    if job.timer, do: Process.cancel_timer(job.timer)

    Enum.each(Map.keys(job.managed), fn pid ->
      if pid != job.worker or kill_worker?, do: Process.exit(pid, :kill)
    end)

    %{job | stopping?: true, outcome: result, timer: nil}
  end

  defp complete_or_continue(%{job: %{stopping?: true, managed: managed} = job} = state)
       when map_size(managed) == 0 do
    Process.demonitor(job.caller_ref, [:flush])
    restoration = restore(job.snapshot)
    result = with_restore_result(job.outcome, restoration)
    if job.reply? and result, do: GenServer.reply(job.from, result)
    cancellation = if restoration == :ok, do: :ok, else: result
    Enum.each(job.cancel_from, &GenServer.reply(&1, cancellation))

    state =
      state
      |> maybe_remember_workspace(job.project_path, job.project_modules, result)
      |> Map.put(:job, nil)
      |> Map.put(:restore_error, if(restoration == :ok, do: nil, else: result))

    {:noreply, state}
  end

  defp complete_or_continue(state), do: {:noreply, state}

  defp remove_managed(managed, pid, ref) do
    case managed do
      %{^pid => ^ref} -> Map.delete(managed, pid)
      _ -> managed
    end
  end

  defp with_restore_result(result, :ok), do: result

  defp with_restore_result({:error, message, details}, {:error, reason}) do
    {:error, message, Map.merge(details, %{restore_failed: true, restore_error: reason})}
  end

  defp with_restore_result(result, {:error, reason}) do
    {:error, "Mix VM state restoration failed: #{reason}",
     %{restore_failed: true, operation_result: inspect(result)}}
  end

  defp maybe_remember_workspace(state, nil, _modules, _result), do: state

  defp maybe_remember_workspace(state, project_path, modules, result) do
    if successful_result?(result) and MapSet.size(modules) > 0 do
      %{
        state
        | workspace_roots: MapSet.put(state.workspace_roots, project_path),
          workspace_modules: MapSet.union(state.workspace_modules, modules)
      }
    else
      state
    end
  end

  defp successful_result?({:ok, _value}), do: true
  defp successful_result?(_result), do: false

  defp snapshot do
    mix? = function_exported?(Mix, :env, 0)

    %{
      cwd: current_cwd(),
      env: Map.new(@env_keys, &{&1, System.get_env(&1)}),
      mix_env: if(mix?, do: Mix.env()),
      mix_shell: if(mix? and function_exported?(Mix, :shell, 0), do: Mix.shell()),
      mix_project: mix_project(),
      code_path: :code.get_path(),
      hex_state: hex_state(),
      protocols: protocol_locations(),
      inets?: inets_running?()
    }
  end

  defp restore(snapshot) when is_map(snapshot) do
    with :ok <- restore_cwd(snapshot.cwd),
         :ok <- restore_env(snapshot.env),
         :ok <- restore_mix(snapshot),
         :ok <- restore_project_stack(snapshot.mix_project),
         :ok <- restore_code_path(snapshot.code_path),
         :ok <- restore_protocols(snapshot.protocols) do
      restore_hex_state(snapshot.hex_state)
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, [])}
  end

  defp restore_env(env) do
    Enum.each(env, fn {key, value} ->
      if value, do: System.put_env(key, value), else: System.delete_env(key)
    end)

    :ok
  end

  defp restore_mix(snapshot) do
    if function_exported?(Mix, :env, 1) and snapshot.mix_env, do: Mix.env(snapshot.mix_env)

    if function_exported?(Mix, :shell, 1) and snapshot.mix_shell,
      do: Mix.shell(snapshot.mix_shell)

    if function_exported?(Mix.Task, :clear, 0), do: Mix.Task.clear()
    :ok
  end

  defp current_cwd do
    case :file.get_cwd() do
      {:ok, cwd} -> List.to_string(cwd)
      {:error, _} -> File.cwd!()
    end
  end

  defp restore_cwd(cwd) when is_binary(cwd) and cwd != "" do
    case :file.set_cwd(String.to_charlist(cwd)) do
      :ok ->
        :ok

      {:error, reason} ->
        case File.cd(cwd) do
          :ok ->
            :ok

          {:error, fallback} ->
            {:error, "cannot restore cwd to #{cwd}: #{inspect(reason)} / #{inspect(fallback)}"}
        end
    end
  end

  defp restore_cwd(_), do: :ok

  defp mix_project do
    if function_exported?(Mix.Project, :get, 0), do: Mix.Project.get()
  end

  defp restore_project_stack(original) do
    if function_exported?(Mix.Project, :get, 0) and function_exported?(Mix.Project, :pop, 0) do
      pop_until(original)
    else
      :ok
    end
  end

  defp pop_until(original) do
    current = Mix.Project.get()

    cond do
      current == original ->
        :ok

      current == nil ->
        :ok

      true ->
        Mix.Project.pop()
        pop_until(original)
    end
  end

  defp protocol_locations do
    for protocol <- [String.Chars, Inspect], into: %{} do
      {protocol, :code.which(protocol)}
    end
  end

  defp restore_protocols(locations) when is_map(locations) do
    Enum.reduce_while(locations, :ok, fn {protocol, path}, :ok ->
      current = :code.which(protocol)

      if current != path and is_list(path) do
        :code.purge(protocol)

        # Replace the current code atomically; deleting it would let another
        # process autoload a protocol and occupy the old-code slot first.
        result =
          :code.load_abs(
            path
            |> List.to_string()
            |> String.replace_suffix(".beam", "")
            |> String.to_charlist()
          )

        case result do
          {:module, ^protocol} -> {:cont, :ok}
          other -> {:halt, {:error, "cannot restore #{inspect(protocol)}: #{inspect(other)}"}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp restore_protocols(_), do: :ok

  defp restore_code_path(path) do
    case :code.set_path(path) do
      true -> :ok
      {:error, reason} -> {:error, "cannot restore code path: #{inspect(reason)}"}
    end
  end

  defp hex_state do
    if Process.whereis(Hex.State) && function_exported?(Hex.State, :get_all, 0) do
      Hex.State.get_all()
    end
  end

  defp restore_hex_state(nil) do
    if Process.whereis(Hex.State), do: Application.stop(:hex), else: :ok
  end

  defp restore_hex_state(state) do
    if Process.whereis(Hex.State) && function_exported?(Hex.State, :put_all, 1) do
      Hex.State.put_all(state)
    else
      {:error, "Hex.State stopped during Mix operation"}
    end
  end

  defp inets_running? do
    Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :inets end)
  end
end
