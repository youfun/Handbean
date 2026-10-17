defmodule Handbean.Extension.Message do
  @moduledoc """
  Extension message injection API.

  Extensions can inject messages into the agent pipeline via this module.
  Internally delegates to `Handbean.PubSub.Session.enqueue_candidate/3`.

  ## Delivery modes

  - `:steer` — delivered during current turn's next tool-execution gap
  - `:follow_up` — delivered after current turn completes
  - `:next_turn` — queued for the next user turn
  """

  alias Handbean.PubSub.Session

  @type delivery :: :steer | :follow_up | :next_turn

  @doc """
  Inject a message into the agent pipeline for the given session.

  Returns `{:ok, ack}` on success or `{:error, reason}` on failure.
  """
  @spec inject(String.t(), String.t(), delivery(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def inject(session_id, content, delivery \\ :steer, opts \\ [])

  def inject(session_id, content, :next_turn, opts) do
    opts = Keyword.put(opts, :deliver_as, :next_turn)

    case Session.enqueue_candidate(session_id, content, opts) do
      :ok -> {:ok, %{action: :enqueued, delivery: :next_turn}}
      {:error, reason} -> {:error, reason}
    end
  end

  def inject(session_id, content, delivery, opts) when delivery in [:steer, :follow_up] do
    opts = Keyword.put(opts, :deliver_as, delivery)

    case Session.enqueue_candidate(session_id, content, opts) do
      :ok -> {:ok, %{action: :enqueued, delivery: delivery}}
      {:error, reason} -> {:error, reason}
    end
  end

  def inject(_session_id, _content, delivery, _opts) do
    {:error, {:invalid_delivery, delivery}}
  end
end
