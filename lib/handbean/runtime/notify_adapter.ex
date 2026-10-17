defmodule Handbean.Runtime.NotifyAdapter do
  @moduledoc """
  Host-facing notification actions. Mix, tests, and an attached desktop
  server use `Noop`. The macOS app installs `MacNotify` only in the BEAM it
  spawned. Android installs `AndroidNotify`.
  """

  alias Handbean.Runtime.Notify

  @callback app_visible?() :: boolean()
  @callback apply(Notify.action()) :: :ok

  defmodule Noop do
    @moduledoc false
    @behaviour Handbean.Runtime.NotifyAdapter

    @impl true
    def app_visible?, do: true

    @impl true
    def apply(_action), do: :ok
  end

  @spec adapter() :: module()
  def adapter do
    Application.get_env(:handbean, :runtime_notify_adapter, Noop)
  end

  @spec app_visible?() :: boolean()
  def app_visible?, do: adapter().app_visible?()

  @spec apply(Notify.action()) :: :ok
  def apply(action), do: adapter().apply(action)

  @doc """
  The macOS shell posts a system banner instead of the embedded page toast.
  Browser and Android adapters leave this false.
  """
  @spec prefers_system_notification?() :: boolean()
  def prefers_system_notification? do
    adapter = adapter()

    function_exported?(adapter, :prefers_system_notification?, 0) and
      adapter.prefers_system_notification?()
  end
end
