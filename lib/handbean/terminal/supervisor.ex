defmodule Handbean.Terminal.Supervisor do
  @moduledoc "Dynamic supervisor for checkout-scoped terminal sessions."

  use DynamicSupervisor

  alias Handbean.CheckoutScope
  alias Handbean.Terminal.{Registry, Session}

  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_terminal(workspace_id, checkout_path, name, opts)
      when is_binary(workspace_id) and is_binary(checkout_path) and is_binary(name) do
    with {:ok, checkout} <- CheckoutScope.resolve(checkout_path) do
      case Registry.lookup(workspace_id, checkout.key, name) do
        {:ok, _pid} ->
          {:error, :already_exists}

        {:error, :not_found} ->
          child_spec = %{
            id: {workspace_id, checkout.key, name},
            start:
              {Session, :start_link,
               [build_session_opts(workspace_id, checkout.path, checkout.key, name, opts)]},
            restart: :temporary
          }

          DynamicSupervisor.start_child(__MODULE__, child_spec)
      end
    end
  end

  def start_terminal(_workspace_id, _checkout_path, _name, _opts),
    do: {:error, :checkout_unavailable}

  def stop_terminal(workspace_id, checkout_path, name) do
    with {:ok, checkout} <- CheckoutScope.resolve(checkout_path),
         {:ok, pid} <- Registry.lookup(workspace_id, checkout.key, name) do
      Session.close(pid)
    end
  end

  def stop_all_for_workspace(workspace_id) do
    Registry.list(workspace_id)
    |> Enum.each(fn %{pid: pid} -> Session.close(pid) end)

    Registry.remove_workspace(workspace_id)
    :ok
  end

  def list_terminals(workspace_id, checkout_path) do
    with {:ok, checkout} <- CheckoutScope.resolve(checkout_path) do
      Registry.list(workspace_id, checkout.key)
      |> Enum.map(&terminal_info/1)
    else
      _ -> []
    end
  end

  def lookup(workspace_id, checkout_path, name) do
    with {:ok, checkout} <- CheckoutScope.resolve(checkout_path) do
      Registry.lookup(workspace_id, checkout.key, name)
    end
  end

  defp terminal_info(%{pid: pid} = entry) do
    info = Session.info(pid) |> Map.take([:name, :status, :cmd, :args, :cwd, :checkout_key])
    Map.merge(info, Map.take(entry, [:checkout_key]))
  end

  defp build_session_opts(workspace_id, checkout_path, checkout_key, name, opts) do
    opts
    |> Keyword.put(:workspace_id, workspace_id)
    |> Keyword.put(:workspace_path, checkout_path)
    |> Keyword.put(:checkout_path, checkout_path)
    |> Keyword.put(:checkout_key, checkout_key)
    |> Keyword.put(:name, name)
  end
end
