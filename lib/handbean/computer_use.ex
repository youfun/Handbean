defmodule Handbean.ComputerUse do
  @moduledoc """
  Product-level owner for Handbean computer-use enablement and host status.

  The host declaration says whether this process has a native backend. The user
  setting independently decides whether Agent runs may use it. Native TCC facts
  and the active desktop lease remain owned by the native host.
  """

  alias Handbean.{Host, Settings}

  @topic "computer_use:status"

  @spec supported?() :: boolean()
  def supported?, do: not is_nil(Host.get(:computer_use_backend))

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    {:ok, settings} = Settings.load_global(opts)
    match?(%{"enabled" => true}, Map.get(settings, "computer_use", %{}))
  end

  @spec set_enabled(boolean(), keyword()) :: :ok | {:error, term()}
  def set_enabled(enabled, opts \\ [])

  def set_enabled(true, opts) do
    if supported?(), do: persist_enabled(true, opts), else: {:error, :unavailable}
  end

  def set_enabled(false, opts) do
    _ = stop_all()
    persist_enabled(false, opts)
  end

  @spec status() :: map()
  def status do
    base = %{
      supported: supported?(),
      enabled: enabled?(),
      backend: backend_name(),
      permissions: :unknown,
      actions: %{}
    }

    if supported?(), do: read_backend_status(base), else: base
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Handbean.PubSub, @topic)

  defp persist_enabled(enabled, opts) do
    case Settings.save_global_section("computer_use", %{"enabled" => enabled}, opts) do
      :ok ->
        broadcast({:computer_use_enabled, enabled})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp read_backend_status(base) do
    case backend_call(:status, []) do
      {:ok, status} when is_map(status) ->
        %{
          base
          | permissions: %{
              screen_recording: status["screen_recording"] == true,
              accessibility: status["accessibility"] == true,
              event_post: status["event_post"] == true
            },
            actions: Map.get(status, "actions", %{})
        }

      {:error, reason} ->
        Map.put(base, :error, reason)

      _ ->
        base
    end
  end

  defp stop_all do
    case backend_call(:stop_all, []) do
      {:ok, _reply} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp backend_call(function, args) do
    case Host.get(:computer_use_backend) do
      backend when is_atom(backend) and not is_nil(backend) ->
        if function_exported?(backend, function, length(args)),
          do: apply(backend, function, args),
          else: {:error, :unsupported}

      _ ->
        {:error, :unavailable}
    end
  end

  defp backend_name do
    case Host.get(:computer_use_backend) do
      Handbean.ComputerUse.Native -> :native_macos
      nil -> :none
      _other -> :custom
    end
  end

  defp broadcast(message) do
    if Process.whereis(Handbean.PubSub),
      do: Phoenix.PubSub.broadcast(Handbean.PubSub, @topic, message),
      else: :ok
  end
end
