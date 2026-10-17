defmodule Handbean.Delivery do
  @moduledoc """
  Outbound delivery boundary for channel replies.

  Transcript persistence records what happened. Delivery is responsible for
  sending assistant/tool/error output back to the originating channel, such as
  SNS or webhook. LiveView remains a PubSub projection and does not need a
  delivery adapter.
  """

  @callback deliver(map(), keyword()) :: :ok | {:error, term()}

  @spec deliver(map(), keyword()) :: :ok | {:error, term()}
  def deliver(entry, opts \\ []) when is_map(entry) do
    adapter =
      Keyword.get(opts, :delivery) || Application.get_env(:handbean, :delivery, __MODULE__.Noop)

    delivery_opts = Keyword.get(opts, :delivery_opts, [])

    adapter.deliver(entry, Keyword.merge(opts, delivery_opts))
  end
end
