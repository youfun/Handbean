defmodule Handbean.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    case Handbean.Agent.ModelConfig.ensure_config() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Handbean] model config skipped: #{reason}")
    end

    children =
      [
        Application.fetch_env!(:handbean, :telemetry_adapter),
        Handbean.Storage.Health,
        Handbean.StorageLock,
        Handbean.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:handbean, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:handbean, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Handbean.PubSub},
        Handbean.Speech.Server,
        Handbean.Documents,
        {Registry, keys: :unique, name: Handbean.SessionRegistry},
        {Registry, keys: :unique, name: Handbean.AgentRunRegistry},
        {Registry, keys: :unique, name: Handbean.AgentRunSupervisorRegistry},
        {Registry, keys: :unique, name: Handbean.AgentRunQueueRegistry},
        {Registry, keys: :unique, name: Handbean.CursorSessionRegistry},
        Handbean.Agent.Auth.Epoch,
        Handbean.Agent.SecretMasking.Store,
        Handbean.Agent.Provider.Cursor.Supervisor,
        Handbean.Preview.Store,
        Handbean.ExportSnapshot.Binding,
        Handbean.Preview.Listener,
        Handbean.Browser.Display,
        Handbean.Tool.Registry,
        Handbean.Workspace.MixOwner,
        Handbean.Platform.WorkspaceEnvironment,
        Handbean.Jobs.Cleaner,
        Handbean.Media.Cleaner,
        Handbean.ConversationArtifacts.Cleaner,
        {DynamicSupervisor, name: Handbean.Jobs.BeamSupervisor, strategy: :one_for_one},
        Handbean.Jobs.Server,
        {Handbean.Extension.Registry, name: Handbean.Extension.Registry},
        Handbean.Extension.Supervisor,
        Handbean.Extension.Mount,
        Handbean.Search.Watcher,
        {Handbean.Extension.HotReloader,
         enabled: Application.get_env(:handbean, :extension_hot_reload, true),
         trusted_project?: Handbean.ProjectTrust.enabled?()}
      ] ++
        terminal_children() ++
        browser_children() ++
        [
          Handbean.SessionSupervisor,
          Handbean.AgentRunSupervisor,
          {Task.Supervisor, name: Handbean.AgentRunTaskSupervisor},
          Handbean.Platform.ProcessRunner.InvocationSupervisor
        ] ++
        Handbean.WorkspaceCommand.child_specs() ++
        [
          Handbean.Agent.Delegation
        ] ++
        Handbean.Runtime.MacNotify.children() ++
        [
          {Task.Supervisor, name: Handbean.WebPush.TaskSupervisor},
          Handbean.WebPush.Dispatcher,
          Handbean.Runtime.TaskTracker,
          Handbean.Schedule.Clock,
          Handbean.Schedule.Recorder
        ] ++
        mcp_children() ++
        [Handbean.EndpointAdapter.implementation()] ++ recovery_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Handbean.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Handbean.EndpointAdapter.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end

  defp recovery_children do
    [
      {Handbean.Agent.TranscriptRecovery,
       recover_on_start: Application.get_env(:handbean, :recover_transcripts, true)}
    ]
  end

  defp terminal_children do
    if Handbean.Terminal.available?() do
      [Handbean.Terminal.Registry, Handbean.Terminal.Supervisor]
    else
      []
    end
  end

  defp browser_children do
    :ok = Handbean.Tool.Builtin.Browser.fix_backend!()

    case Handbean.Host.browser_backend() do
      :cli ->
        relay_children =
          if Application.get_env(:handbean, :chrome_control, true) do
            [
              Handbean.Browser.ChromeRelay.Server,
              {Bandit,
               plug: Handbean.Browser.ChromeRelay.Router,
               scheme: :http,
               ip: {127, 0, 0, 1},
               port: Application.get_env(:handbean, :chrome_relay_port, 17_688),
               startup_log: false,
               thousand_island_options: [
                 supervisor_options: [name: Handbean.Browser.ChromeRelay.Listener]
               ],
               websocket_options: [max_frame_size: 1_048_576]}
            ]
          else
            []
          end

        [Handbean.Browser.Registry, Handbean.Browser.Supervisor] ++ relay_children

      :webview ->
        [
          {Registry, keys: :unique, name: Handbean.Browser.WebViewRegistry},
          Handbean.Browser.WebViewSupervisor
        ]

      _ ->
        []
    end
  end

  defp mcp_children do
    if Handbean.Host.mcp?() do
      [Handbean.MCP.RuntimeSupervisor, Handbean.MCP, Handbean.MCP.DeferredBootstrap]
    else
      []
    end
  end
end
