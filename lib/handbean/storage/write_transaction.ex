defmodule Handbean.Storage.WriteTransaction do
  @moduledoc """
  Bounded SQLite contention recovery for database-only write transactions.

  Acquire the writer before reading to avoid WAL snapshot upgrade failures.
  Retry only after the entire transaction has rolled back. Callbacks must not
  perform external effects. Nested calls leave recovery to the outer owner.
  """

  alias Handbean.Repo
  alias Handbean.Storage.ErrorClassifier

  @attempts 3

  def run(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      case Repo.transaction(fun) do
        {:error, error} = result ->
          if busy?(error), do: Repo.rollback(error), else: result

        result ->
          result
      end
    else
      attempt(fun, @attempts)
    end
  end

  defp attempt(fun, remaining) do
    case transaction(fun) do
      {:error, error} = result when remaining > 1 ->
        if busy?(error), do: attempt(fun, remaining - 1), else: result

      result ->
        result
    end
  end

  # SQLite's configured busy handler supplies the wait between attempts. With
  # Repo's 5s busy_timeout there are at most three writer-acquisition waits (not a total deadline);
  # pool checkout and callback execution have their own timeouts. No unbounded retry
  # and no replay of a tool/provider operation. Other database failures escape.
  defp transaction(fun) do
    Repo.transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if busy?(error),
        do: {:error, error},
        else: reraise(error, __STACKTRACE__)
  end

  # Classification owns message variants; retry eligibility still requires the
  # actual SQLite driver exception, never arbitrary application error text.
  defp busy?(%Exqlite.Error{message: message} = error) when is_binary(message),
    do: ErrorClassifier.classify(error) == :busy

  defp busy?(_error), do: false
end
