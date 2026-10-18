platform_excludes =
  case :os.type() do
    {:unix, :linux} ->
      [:darwin_process]

    {:unix, :darwin} ->
      os_sandbox = if File.regular?("/usr/bin/sandbox-exec"), do: [], else: [:os_sandbox]
      [:linux_sandbox] ++ os_sandbox

    _ ->
      [:unix_jobs, :darwin_process, :linux_sandbox, :os_sandbox]
  end

ExUnit.configure(exclude: [:slow, :e2e, :external_api] ++ platform_excludes)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, :manual)

# Start Tool Registry for agent/tool tests.
# If the app is already running, this is a no-op.
case Handbean.Tool.Registry.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

unless Process.whereis(Handbean.ExportSnapshot.Binding) do
  {:ok, _} = Handbean.ExportSnapshot.Binding.start_link([])
end

# Start Extension Registry for hook/extension tests.
# If the app is already running, this is a no-op.
unless Process.whereis(Handbean.Extension.Registry) do
  Handbean.Extension.Registry.start_link(name: Handbean.Extension.Registry)
end

unless Process.whereis(Handbean.Extension.Supervisor) do
  Handbean.Extension.Supervisor.start_link([])
end

unless Process.whereis(Handbean.Extension.Mount) do
  Handbean.Extension.Mount.start_link([])
end

unless Process.whereis(Handbean.Workspace.MixOwner) do
  {:ok, _} = Handbean.Workspace.MixOwner.start_link([])
end
