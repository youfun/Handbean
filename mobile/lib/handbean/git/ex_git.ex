defmodule Handbean.Git.ExGit do
  @moduledoc """
  libgit2 Git backend for Android/iOS hosts.

  The desktop Mix project does not compile or depend on ExGit. The phone
  host injects this module through `Handbean.Host` `:git_backend` at boot.
  """

  @behaviour Handbean.Git.Backend

  @impl true
  def available do
    cond do
      not Code.ensure_loaded?(ExGit) ->
        {:error, "ExGit/libgit2 is not loaded on this host"}

      function_exported?(ExGit, :nif_loaded?, 0) and ExGit.nif_loaded?() ->
        :ok

      true ->
        {:error, "ExGit/libgit2 is not loaded on this host"}
    end
  end

  @impl true
  def init(path), do: ExGit.init(path)

  @impl true
  def open(path, opts), do: ExGit.open(path, opts)

  @impl true
  def workdir(repo), do: ExGit.workdir(repo)

  @impl true
  def status(repo), do: ExGit.status(repo)

  @impl true
  def diff(repo, :worktree), do: ExGit.diff(repo, :worktree)
  def diff(repo, :staged), do: ExGit.diff(repo, :staged)

  def diff(repo, {from, to}) when is_binary(from) and is_binary(to),
    do: ExGit.diff(repo, from, to)

  def diff(repo, _mode), do: ExGit.diff(repo)

  @impl true
  def add(repo, paths), do: ExGit.add(repo, paths)

  @impl true
  def reset(repo, type, target) when type in [:soft, :mixed, :hard] do
    ExGit.reset(repo, type, target)
  end

  @impl true
  def reset_paths(repo, paths), do: ExGit.reset(repo, paths)

  @impl true
  def commit(repo, message, opts), do: ExGit.commit(repo, message, opts)

  @impl true
  def log(repo, opts), do: ExGit.log(repo, opts)

  @impl true
  def branches(repo), do: ExGit.branches(repo)

  @impl true
  def create_branch(repo, name, opts), do: ExGit.create_branch(repo, name, opts)

  @impl true
  def checkout(repo, target, opts), do: ExGit.checkout(repo, target, opts)

  @impl true
  def clone(url, path, opts), do: ExGit.clone(url, path, opts)

  @impl true
  def fetch(repo, opts), do: ExGit.fetch(repo, opts)

  @impl true
  def pull(repo, opts), do: ExGit.pull(repo, opts)

  @impl true
  def push(repo, opts), do: ExGit.push(repo, opts)

  @impl true
  def remotes(repo), do: ExGit.remotes(repo)

  @impl true
  def remote_add(repo, name, url), do: ExGit.remote_add(repo, name, url)

  @impl true
  def remote_set_url(repo, name, url), do: ExGit.remote_set_url(repo, name, url)
end
