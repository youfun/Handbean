defmodule Handbean.Git.Backend do
  @moduledoc """
  Git storage backend used by `Handbean.Git`.

  The facade owns workspace path checks, HTTPS URL rules, identity, and
  result formatting. Backends implement repository operations only.
  """

  @type repo :: term()
  @type error :: {:error, term()}

  @callback available() :: :ok | {:error, String.t()}
  @callback init(Path.t()) :: {:ok, repo()} | error()
  @callback open(Path.t(), keyword()) :: {:ok, repo()} | error()
  @callback workdir(repo()) :: {:ok, String.t()} | error()
  @callback status(repo()) :: {:ok, map()} | error()
  @callback diff(repo(), term()) :: {:ok, String.t()} | error()
  @callback add(repo(), [String.t()]) :: :ok | error()
  @callback reset(repo(), :soft | :mixed | :hard, String.t()) :: :ok | error()
  @callback reset_paths(repo(), [String.t()]) :: :ok | error()
  @callback commit(repo(), String.t(), keyword()) :: {:ok, String.t()} | error()
  @callback log(repo(), keyword()) :: {:ok, [map()]} | error()
  @callback branches(repo()) :: {:ok, [map()]} | error()
  @callback create_branch(repo(), String.t(), keyword()) :: :ok | error()
  @callback checkout(repo(), String.t(), keyword()) :: :ok | error()
  @callback clone(String.t(), Path.t(), keyword()) :: {:ok, repo()} | error()
  @callback fetch(repo(), keyword()) :: :ok | error()
  @callback pull(repo(), keyword()) :: :up_to_date | :fast_forward | error()
  @callback push(repo(), keyword()) :: :ok | error()
  @callback remotes(repo()) :: {:ok, [map()]} | error()
  @callback remote_add(repo(), String.t(), String.t()) :: :ok | error()
  @callback remote_set_url(repo(), String.t(), String.t()) :: :ok | error()
end
