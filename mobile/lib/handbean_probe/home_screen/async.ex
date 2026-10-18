defmodule HandbeanProbe.HomeScreen.Async do
  @moduledoc """
  Off-screen IO for `HandbeanProbe.HomeScreen`.

  Mob does not supervise screens, so the screen process must never block on
  disk. Every read or write that is not a single small stat runs here under
  `HandbeanProbe.TaskSupervisor` and reports back as
  `{ref, {kind, generation, result}}`. `run/4` registers the task reference
  in `HandbeanProbe.PendingRequests` (via `HandbeanProbe.HomeScreen.Requests`), so
  `HomeScreen` correlates the reply with `PendingRequests.take/3`: the wire
  generation must match and the scope must not have moved on.

  By default a kind is its own scope and each `run/4` bumps it (latest wins).
  `scope: :composer` binds the task to the composer instead, without bumping.
  `Task.Supervisor.async_nolink/2` also delivers a `:DOWN` message that the
  screen ignores.
  """

  alias HandbeanProbe.HomeScreen.Requests

  @spec run(map(), atom(), (-> term()), keyword()) :: map()
  def run(socket, kind, fun, opts \\ []) when is_atom(kind) and is_function(fun, 0) do
    scope = Keyword.get(opts, :scope, kind)

    {generation, socket} =
      cond do
        Keyword.get(opts, :bump?, scope == kind) == false ->
          {Requests.generation(socket, scope), socket}

        scope == kind ->
          Requests.bump(socket, scope)

        true ->
          {Requests.generation(socket, scope), socket}
      end

    task =
      Task.Supervisor.async_nolink(HandbeanProbe.TaskSupervisor, fn ->
        {kind, generation, fun.()}
      end)

    Requests.register(socket, task.ref, kind,
      scope: scope,
      generation: generation,
      ctx: Keyword.get(opts, :ctx, %{})
    )
  end

  @doc "Fire-and-forget IO; the reply is still tagged so tests can wait for it."
  @spec fire(atom(), (-> term())) :: Task.t()
  def fire(tag, fun) when is_atom(tag) and is_function(fun, 0) do
    Task.Supervisor.async_nolink(HandbeanProbe.TaskSupervisor, fn ->
      {tag, nil, fun.()}
    end)
  end
end
