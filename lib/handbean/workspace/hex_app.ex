defmodule Handbean.Workspace.HexApp do
  @moduledoc """
  Hex 2.4.1 application callback used with the packaged mobile toolchain.

  Matches Hex.Application's production children, but does not start an
  `:httpc` profile. HTTP goes through `Handbean.Workspace.HexHttp`. This must
  not be used to replace an already-running host Hex.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Mix.SCM.append(Hex.SCM)
    Mix.RemoteConverger.register(Hex.RemoteConverger)

    Supervisor.start_link(
      [
        Hex.Netrc.Cache,
        Hex.OAuth,
        Hex.Repo,
        Hex.State,
        Hex.Server,
        {Hex.Parallel, [:hex_fetcher]},
        Hex.Registry.Server,
        Hex.UpdateChecker
      ],
      strategy: :one_for_one,
      name: Hex.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    Mix.RemoteConverger.register(nil)

    if function_exported?(Mix.SCM, :delete, 1) do
      Mix.SCM.delete(Hex.SCM)
    end

    :ok
  end
end
