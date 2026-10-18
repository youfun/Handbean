defmodule Handbean.TestSupport.E2EHarness do
  @moduledoc false

  alias Handbean.Agent.Coordinator
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session

  @models ~s({"providers":{"fake":{"baseUrl":"http://127.0.0.1","api":"openai-chat-completions","apiKey":"sk-fake","models":[{"id":"fake-model","name":"Fake Model"}]}}})

  def isolate_home!(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{Ecto.UUID.generate()}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)
    File.write!(Path.join(root, "models.json"), @models)

    old = %{
      home: System.get_env("HOME"),
      models: System.get_env("HANDBEAN_MODELS_FILE"),
      settings: System.get_env("HANDBEAN_GLOBAL_SETTINGS_FILE"),
      workspaces: System.get_env("HANDBEAN_WORKSPACES_FILE"),
      provider: Application.get_env(:handbean, :test_provider),
      host: Application.get_env(:handbean, :host)
    }

    File.mkdir_p!(Path.join(home, ".handbean"))
    System.put_env("HOME", home)
    System.put_env("HANDBEAN_MODELS_FILE", Path.join(root, "models.json"))
    System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", Path.join(home, ".handbean/settings.json"))
    System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(home, ".handbean/workspaces.json"))

    ExUnit.Callbacks.on_exit(fn ->
      stop_runtime!()
      restore_env("HOME", old.home)
      restore_env("HANDBEAN_MODELS_FILE", old.models)
      restore_env("HANDBEAN_GLOBAL_SETTINGS_FILE", old.settings)
      restore_env("HANDBEAN_WORKSPACES_FILE", old.workspaces)
      restore_app(:test_provider, old.provider)
      restore_app(:host, old.host)
      File.rm_rf(root)
    end)

    %{root: root, home: home, workspace: workspace}
  end

  def use_fake_provider!(scenario) do
    Application.put_env(:handbean, :test_provider, %{
      module: Handbean.TestSupport.FakeProvider,
      scenario: scenario
    })
  end

  def with_host!(attrs) do
    current = Application.get_env(:handbean, :host, %{})
    Handbean.Host.put!(Map.merge(current, attrs))
  end

  def register_tool!(module) do
    case Handbean.Tool.Registry.register(module, override: true) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  def transcript(id) do
    {:ok, entries} = ConversationTranscriptStore.list(id)
    entries
  end

  def await_run_end(id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_terminal(id, deadline)
  end

  defp await_terminal(id, deadline) do
    receive do
      {:agent_event, %{kind: :run_end, payload: %{status: status} = payload}}
      when status in [
             "completed",
             :completed,
             "cancelled",
             :cancelled,
             "error",
             :error,
             :stalled,
             "stalled"
           ] ->
        payload

      {:agent_event, %{kind: :run_end}} ->
        await_terminal(id, deadline)

      {:agent_event, %{kind: kind}}
      when kind in [:tool_approval_requested, :stall_check_requested] ->
        await_terminal(id, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise "expected run_end for #{id}"
    end
  end

  def cancel!(id) when is_binary(id) do
    _ = Coordinator.cancel(id)
    _ = Handbean.AgentRunSupervisor.stop_run(id)
    if Session.whereis(id), do: Session.snapshot(id)
    _ = Handbean.SessionSupervisor.stop_session(id)
    :ok
  end

  def stop_runtime! do
    for id <- registered_ids(Handbean.AgentRunSupervisorRegistry) do
      Handbean.AgentRunSupervisor.stop_run(id)
    end

    for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
      Task.Supervisor.terminate_child(Handbean.AgentRunTaskSupervisor, pid)
    end

    for {_, pid, _, _} <- Handbean.SessionSupervisor.which_sessions() do
      GenServer.call(pid, :snapshot)
      DynamicSupervisor.terminate_child(Handbean.SessionSupervisor, pid)
    end

    # Drain lifecycle consumers before switching HOME or deleting its persisted files.
    GenServer.call(Handbean.Runtime.TaskTracker, :snapshot)
    # The transcript index no longer exposes a Journal invalidation API in this
    # codebase revision; keep this as a no-op so e2e runtime teardown stays stable.
    :ok
    home = Handbean.Home.path()

    for path <- registered_ids(ExFff.Registry),
        path == home or String.starts_with?(path, home <> "/"),
        {pid, _} <- Registry.lookup(ExFff.Registry, path) do
      GenServer.stop(pid)
    end

    :ok
  end

  defp registered_ids(registry) do
    Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app(key, nil), do: Application.delete_env(:handbean, key)
  defp restore_app(key, value), do: Application.put_env(:handbean, key, value)
end
