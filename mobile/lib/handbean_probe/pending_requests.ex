defmodule HandbeanProbe.PendingRequests do
  @moduledoc """
  The one request-correlation table of `HandbeanProbe.HomeScreen`.

  Everything the screen waits for is an `Entry` of `{ref, kind, generation,
  deadline}` plus a small `ctx`:

    * platform requests to Kotlin (`ref` is the `request_id` string; kinds
      `:import`, `:pick_photos`, `:open_url`, `:delivery_export`,
      `:approval_export`, `:open_snapshot`, `:share_snapshot`);
    * off-screen tasks started by `HandbeanProbe.HomeScreen.Async` (`ref` is the
      task monitor reference; kinds `:share_intakes_ready`, `:folder_listed`,
      `:model_settings_loaded`, …).

  Each entry is bound to a *scope*: a named generation counter held in this
  struct (`:composer`, `:workspace_open`, `:share`, `:models`, `:folder`, or
  the entry's own kind for latest-wins tasks). `bump/2` invalidates every
  entry bound to that scope; `take/3` returns `:superseded` for them. This
  replaces the former `composer_generation` / `workspace_open_generation` /
  `share_generation` / `models_generation` / `folder_generation` assigns and
  the `pending_requests` map.

  A `timeout_ms` schedules `{:pending_request_timeout, ref}` to the owner via
  `Process.send_after/3`; `expire/2` removes the entry when that fires. The
  wire `generation` echoed by Kotlin is checked against the entry
  (`{:error, {:generation_mismatch, ...}}`), so a reply for an older
  generation is dropped instead of being applied.

  Pure data: every function returns the updated struct. The timer messages
  target the process that called `register/4`.
  """

  defmodule Entry do
    @moduledoc "One awaited reply."
    @enforce_keys [:ref, :kind, :scope, :generation]
    defstruct [:ref, :kind, :scope, :generation, :deadline, :timer, ctx: %{}]

    @type t :: %__MODULE__{
            ref: term(),
            kind: atom(),
            scope: atom(),
            generation: integer(),
            deadline: integer() | nil,
            timer: reference() | nil,
            ctx: map()
          }
  end

  defstruct entries: %{}, generations: %{composer: 1}

  @type t :: %__MODULE__{entries: %{term() => Entry.t()}, generations: %{atom() => integer()}}
  @type take_error :: :unknown | :superseded | {:generation_mismatch, integer(), term()}

  @timeout_message :pending_request_timeout

  @doc "Empty table. The composer generation starts at 1, every other scope at 0."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Tag of the message `Process.send_after/3` delivers: `{tag, ref}`."
  def timeout_message, do: @timeout_message

  # ── generations ──

  @doc "Current generation of `scope` (0 until first bump, composer starts at 1)."
  @spec generation(t(), atom()) :: integer()
  def generation(%__MODULE__{generations: gens}, scope), do: Map.get(gens, scope, 0)

  @doc "Advance `scope`; every entry bound to it becomes superseded."
  @spec bump(t(), atom()) :: {integer(), t()}
  def bump(%__MODULE__{} = pr, scope) do
    next = generation(pr, scope) + 1
    {next, %{pr | generations: Map.put(pr.generations, scope, next)}}
  end

  @doc "Is `generation` the live one for `scope`?"
  @spec current?(t(), atom(), term()) :: boolean()
  def current?(%__MODULE__{} = pr, scope, generation), do: generation(pr, scope) == generation

  # ── entries ──

  @doc """
  Register a reply to wait for.

  Options: `:scope` (default `kind`), `:generation` (default the scope's
  current generation), `:ctx`, `:timeout_ms` (nil = no deadline), `:owner`
  (pid that receives the timeout, default `self()`).
  """
  @spec register(t(), term(), atom(), keyword()) :: {Entry.t(), t()}
  def register(%__MODULE__{} = pr, ref, kind, opts \\ []) when is_atom(kind) do
    scope = Keyword.get(opts, :scope, kind)
    generation = Keyword.get(opts, :generation, generation(pr, scope))
    timeout_ms = Keyword.get(opts, :timeout_ms)
    owner = Keyword.get(opts, :owner, self())

    {deadline, timer} =
      if is_integer(timeout_ms) and timeout_ms >= 0 do
        {System.monotonic_time(:millisecond) + timeout_ms,
         Process.send_after(owner, {@timeout_message, ref}, timeout_ms)}
      else
        {nil, nil}
      end

    entry = %Entry{
      ref: ref,
      kind: kind,
      scope: scope,
      generation: generation,
      deadline: deadline,
      timer: timer,
      ctx: Keyword.get(opts, :ctx, %{})
    }

    {entry, %{pr | entries: Map.put(pr.entries, ref, entry)}}
  end

  @doc """
  Consume the entry for `ref`. The entry is removed whatever the outcome.

  `wire_generation` is the generation echoed on the wire (`:any` when the
  transport carries none). Errors: `:unknown` (no such ref), `{:generation_mismatch,
  expected, got}` (wire disagrees with the entry), `:superseded` (the scope
  moved on since registration).
  """
  @spec take(t(), term(), term()) :: {:ok, Entry.t(), t()} | {:error, take_error(), t()}
  def take(%__MODULE__{} = pr, ref, wire_generation \\ :any) do
    case Map.pop(pr.entries, ref) do
      {nil, _} ->
        {:error, :unknown, pr}

      {%Entry{} = entry, entries} ->
        cancel_timer(entry)
        pr = %{pr | entries: entries}

        cond do
          wire_generation != :any and wire_generation != entry.generation ->
            {:error, {:generation_mismatch, entry.generation, wire_generation}, pr}

          not current?(pr, entry.scope, entry.generation) ->
            {:error, :superseded, pr}

          true ->
            {:ok, entry, pr}
        end
    end
  end

  @doc "Remove the entry whose deadline fired. `:error` when it was already taken."
  @spec expire(t(), term()) :: {:ok, Entry.t(), t()} | :error
  def expire(%__MODULE__{} = pr, ref) do
    case Map.pop(pr.entries, ref) do
      {nil, _} -> :error
      {%Entry{} = entry, entries} -> {:ok, entry, %{pr | entries: entries}}
    end
  end

  @doc "Remove and return every entry bound to one of `scopes`, cancelling their timers."
  @spec drop_scope(t(), atom() | [atom()]) :: {[Entry.t()], t()}
  def drop_scope(%__MODULE__{} = pr, scopes) do
    scopes = List.wrap(scopes)
    {dropped, kept} = Enum.split_with(pr.entries, fn {_ref, e} -> e.scope in scopes end)
    dropped = Enum.map(dropped, fn {_ref, e} -> e end)
    Enum.each(dropped, &cancel_timer/1)
    {dropped, %{pr | entries: Map.new(kept)}}
  end

  @doc "Remove and return every entry, cancelling their timers."
  @spec drop_all(t()) :: {[Entry.t()], t()}
  def drop_all(%__MODULE__{} = pr) do
    entries = Map.values(pr.entries)
    Enum.each(entries, &cancel_timer/1)
    {entries, %{pr | entries: %{}}}
  end

  @spec has?(t(), term()) :: boolean()
  def has?(%__MODULE__{entries: entries}, ref), do: Map.has_key?(entries, ref)

  @spec fetch(t(), term()) :: {:ok, Entry.t()} | :error
  def fetch(%__MODULE__{entries: entries}, ref), do: Map.fetch(entries, ref)

  @spec ctx(t(), term()) :: map() | nil
  def ctx(%__MODULE__{} = pr, ref) do
    case fetch(pr, ref) do
      {:ok, entry} -> entry.ctx
      :error -> nil
    end
  end

  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: Map.values(entries)

  @spec by_kind(t(), atom()) :: [Entry.t()]
  def by_kind(%__MODULE__{} = pr, kind), do: pr |> entries() |> Enum.filter(&(&1.kind == kind))

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: map_size(entries)

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: entries}), do: entries == %{}

  defp cancel_timer(%Entry{timer: nil}), do: :ok

  defp cancel_timer(%Entry{timer: timer}) do
    Process.cancel_timer(timer)
    :ok
  end
end
