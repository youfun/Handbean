defmodule HandbeanProbe.HomeScreen.Requests do
  @moduledoc """
  Socket-level facade over the `pending_requests` assign, a
  `HandbeanProbe.PendingRequests`. Every domain registers, takes and bumps
  through here so the table and its generation counters have one owner.

  Deadlines: system-UI and export requests use `android_intent_await_ms`
  (20 s, the same deadline Kotlin gets in the payload). Picker kinds
  (`:import`, `:pick_photos`) have no deadline by default — the user is inside
  a system picker for as long as they like; a composer reset cancels them.
  `:platform_picker_timeout_ms` can set one.
  """

  alias HandbeanProbe.PendingRequests

  @picker_kinds [:import, :pick_photos]
  @default_await_ms 20_000

  @spec table(map()) :: PendingRequests.t()
  def table(%{assigns: assigns}), do: Map.get(assigns, :pending_requests) || PendingRequests.new()

  @spec put(map(), PendingRequests.t()) :: map()
  def put(socket, %PendingRequests{} = pr), do: put_assign(socket, :pending_requests, pr)

  @spec generation(map(), atom()) :: integer()
  def generation(socket, scope), do: PendingRequests.generation(table(socket), scope)

  @doc "Composer generation: the scope every platform request is bound to."
  @spec composer_generation(map()) :: integer()
  def composer_generation(socket), do: generation(socket, :composer)

  @spec current?(map(), atom(), term()) :: boolean()
  def current?(socket, scope, generation),
    do: PendingRequests.current?(table(socket), scope, generation)

  @spec bump(map(), atom()) :: {integer(), map()}
  def bump(socket, scope) do
    {generation, pr} = PendingRequests.bump(table(socket), scope)
    {generation, put(socket, pr)}
  end

  @doc "Register `ref` under `kind`. Platform request kinds get their default deadline."
  @spec register(map(), term(), atom(), keyword()) :: map()
  def register(socket, ref, kind, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :timeout_ms, fn -> timeout_ms(kind) end)
    {_entry, pr} = PendingRequests.register(table(socket), ref, kind, opts)
    put(socket, pr)
  end

  @doc "Register a platform request (`request_id`) bound to the composer with its ctx."
  @spec track(map(), String.t(), atom(), map()) :: map()
  def track(socket, request_id, kind, ctx) when is_binary(request_id) and is_map(ctx) do
    ctx = ctx |> Map.put(:kind, kind) |> Map.put(:request_id, request_id)

    socket
    |> register(request_id, kind, scope: :composer, ctx: ctx)
    |> put_assign(:last_platform_request, request_id)
  end

  @spec take(map(), term(), term()) ::
          {:ok, PendingRequests.Entry.t(), map()} | {:error, PendingRequests.take_error(), map()}
  def take(socket, ref, wire_generation \\ :any) do
    case PendingRequests.take(table(socket), ref, wire_generation) do
      {:ok, entry, pr} -> {:ok, entry, put(socket, pr)}
      {:error, reason, pr} -> {:error, reason, put(socket, pr)}
    end
  end

  @spec expire(map(), term()) :: {:ok, PendingRequests.Entry.t(), map()} | :error
  def expire(socket, ref) do
    case PendingRequests.expire(table(socket), ref) do
      {:ok, entry, pr} -> {:ok, entry, put(socket, pr)}
      :error -> :error
    end
  end

  @spec drop_scope(map(), atom() | [atom()]) :: {[PendingRequests.Entry.t()], map()}
  def drop_scope(socket, scopes) do
    {entries, pr} = PendingRequests.drop_scope(table(socket), scopes)
    {entries, put(socket, pr)}
  end

  @spec has?(map(), term()) :: boolean()
  def has?(socket, ref), do: PendingRequests.has?(table(socket), ref)

  @spec ctx(map(), term()) :: map() | nil
  def ctx(socket, ref), do: PendingRequests.ctx(table(socket), ref)

  @doc "Default deadline for a request kind; `nil` means none."
  @spec timeout_ms(atom()) :: non_neg_integer() | nil
  def timeout_ms(kind) when kind in @picker_kinds,
    do: Application.get_env(:handbean_probe, :platform_picker_timeout_ms)

  def timeout_ms(kind)
      when kind in [
             :open_url,
             :delivery_export,
             :approval_export,
             :open_snapshot,
             :share_snapshot
           ],
      do: Application.get_env(:handbean_probe, :android_intent_await_ms, @default_await_ms)

  def timeout_ms(_kind), do: nil

  # `Mob.Socket.assign/3` only accepts the struct; delivery unit tests build
  # bare-map sockets.
  defp put_assign(%Mob.Socket{} = socket, key, value), do: Mob.Socket.assign(socket, key, value)

  defp put_assign(%{assigns: assigns} = socket, key, value),
    do: %{socket | assigns: Map.put(assigns, key, value)}
end
