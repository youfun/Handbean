defmodule Handbean.MCP.DeferredBootstrap do
  @moduledoc """
  Defers MCP bootstrap until after the application supervision tree is fully up.

  Req/Finch needs the app to be fully started before HTTP-based MCP servers
  (like stepsearch) can connect. This worker starts after the supervisor and
  triggers bootstrap with a short delay.
  """
  use GenServer

  require Logger

  @delay_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    :timer.send_after(@delay_ms, :bootstrap)
    {:ok, %{bootstrapped: false}}
  end

  @impl true
  def handle_info(:bootstrap, %{bootstrapped: true} = state), do: {:noreply, state}

  def handle_info(:bootstrap, state) do
    # If mcp__ tools are already in the registry (e.g. maybe_bootstrap_mcp ran first),
    # skip to avoid duplicate registration from another BEAM's GenServer.
    already_bootstrapped =
      Enum.any?(Handbean.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))

    if already_bootstrapped do
      Logger.info("[MCP] Deferred bootstrap skipped — mcp__ tools already registered")
      {:noreply, %{state | bootstrapped: true}}
    else
      project = if Handbean.ProjectTrust.enabled?(), do: project_dir(), else: nil

      case Handbean.MCP.bootstrap(project: project) do
        {:ok, result} ->
          Logger.info("[MCP] Deferred bootstrap: #{length(result.registered)} tools registered")

          if Map.get(result, :server_errors, []) != [] do
            Logger.warning(
              "[MCP] #{length(result.server_errors)} server(s) failed during deferred bootstrap"
            )
          end

        {:error, reason} ->
          Logger.warning("[MCP] Deferred bootstrap failed (non-fatal): #{inspect(reason)}")
      end

      {:noreply, %{state | bootstrapped: true}}
    end
  end

  defp project_dir do
    System.get_env("MIX_EXS_PATH", File.cwd!())
    |> Path.dirname()
  end
end
