defmodule Handbean.Git do
  @moduledoc """
  Workspace-scoped Git facade.

  Path permissions stay here. Android/iOS hosts inject `Handbean.Git.ExGit`
  at boot through `Handbean.Host` `:git_backend` and register the builtin Git
  tool. Direct application callers may still use the CLI backend, but desktop
  agents choose the repository command-line workflow through `bash`.

  HTTPS clone/fetch/push and fast-forward pull are allowed; SSH is not.
  Credentials are passed per call and never written into a URL.
  """

  alias Handbean.Git.{CLI, CredentialGuard}
  alias Handbean.Host

  @identity [name: "Handbean Agent", email: "agent@sigil.local"]

  @type action ::
          :init
          | :status
          | :diff
          | :add
          | :reset
          | :commit
          | :log
          | :branches
          | :create_branch
          | :checkout
          | :clone
          | :fetch
          | :pull
          | :push
          | :remotes
          | :remote_add
          | :remote_set_url

  @spec backend() :: module()
  def backend do
    case Host.get(:git_backend) do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> CLI
    end
  end

  @spec backend_kind() :: :host_git_cli | :ex_git_libgit2 | :injected
  def backend_kind do
    case backend() do
      CLI -> :host_git_cli
      Handbean.Git.ExGit -> :ex_git_libgit2
      _ -> :injected
    end
  end

  @spec perform(action(), Path.t(), Path.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, String.t()} | {:error, String.t(), map()}
  def perform(action, workspace, path, opts \\ []) do
    with {:ok, workspace} <- require_workspace(workspace),
         {:ok, resolved} <- resolve_target(action, path, workspace) do
      run(action, workspace, resolved, opts)
    end
  end

  defp run(action, workspace, resolved, opts) do
    backend = backend()

    case backend.available() do
      :ok -> do_run(action, backend, workspace, resolved, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run(:init, backend, workspace, resolved, _opts) do
    with :ok <- assert_inside(resolved, workspace),
         {:ok, repo} <- backend.init(resolved),
         {:ok, workdir} <- backend.workdir(repo) do
      {:ok, "initialized git repository at #{display(resolved, workspace)}",
       %{action: :init, path: resolved, workdir: workdir}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:status, backend, workspace, resolved, _opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         {:ok, status} <- backend.status(repo) do
      {:ok, format_status(status), Map.put(status, :action, :status)}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:diff, backend, workspace, resolved, opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         {:ok, patch} <- backend.diff(repo, opts[:mode] || :head) do
      text = if patch == "", do: "(no diff)", else: patch
      {:ok, text, %{action: :diff, bytes: byte_size(patch)}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:add, backend, workspace, resolved, opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         {:ok, paths} <- resolve_paths(backend, opts[:paths] || [], workspace, repo),
         :ok <- backend.add(repo, paths) do
      {:ok, "staged #{Enum.join(paths, ", ")}", %{action: :add, paths: paths}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:reset, backend, workspace, resolved, opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         {:ok, result} <- do_reset(backend, repo, workspace, opts) do
      {:ok, result, %{action: :reset}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:commit, backend, workspace, resolved, opts) do
    message = opts[:message]

    cond do
      not is_binary(message) or String.trim(message) == "" ->
        {:error, "message is required"}

      true ->
        with {:ok, repo} <- open(backend, resolved, workspace),
             {:ok, oid} <- backend.commit(repo, message, identity(opts)) do
          {:ok, "committed #{oid} #{String.trim(message)}", %{action: :commit, oid: oid}}
        else
          {:error, reason} -> format_error(reason)
        end
    end
  end

  defp do_run(:log, backend, workspace, resolved, opts) do
    limit = opts[:limit] || 20

    with {:ok, repo} <- open(backend, resolved, workspace),
         {:ok, commits} <- backend.log(repo, limit: limit) do
      {:ok, format_log(commits), %{action: :log, commits: commits}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:branches, backend, workspace, resolved, _opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         {:ok, branches} <- backend.branches(repo) do
      {:ok, format_branches(branches), %{action: :branches, branches: branches}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:create_branch, backend, workspace, resolved, opts) do
    name = opts[:name]

    cond do
      not is_binary(name) or String.trim(name) == "" ->
        {:error, "name is required"}

      true ->
        with {:ok, repo} <- open(backend, resolved, workspace),
             :ok <- backend.create_branch(repo, name, force: opts[:force] == true) do
          {:ok, "created branch #{name}", %{action: :create_branch, name: name}}
        else
          {:error, reason} -> format_error(reason)
        end
    end
  end

  defp do_run(:checkout, backend, workspace, resolved, opts) do
    target = opts[:target] || opts[:name]

    cond do
      not is_binary(target) or String.trim(target) == "" ->
        {:error, "target is required"}

      true ->
        with {:ok, repo} <- open(backend, resolved, workspace),
             :ok <- backend.checkout(repo, target, force: opts[:force] == true) do
          {:ok, "checked out #{target}", %{action: :checkout, target: target}}
        else
          {:error, reason} -> format_error(reason)
        end
    end
  end

  defp do_run(:clone, backend, workspace, resolved, opts) do
    url = opts[:url]

    cond do
      not is_binary(url) or String.trim(url) == "" ->
        {:error, "url is required"}

      true ->
        with :ok <- assert_https_url(url),
             :ok <- assert_clone_credentials(backend, url, workspace, opts),
             :ok <- assert_inside(resolved, workspace),
             {:ok, repo} <- backend.clone(url, resolved, auth_opts(opts)),
             {:ok, workdir} <- backend.workdir(repo) do
          {:ok, "cloned #{url} into #{display(resolved, workspace)}",
           %{action: :clone, path: resolved, workdir: workdir}}
        else
          {:error, reason} -> format_error(reason)
        end
    end
  end

  defp do_run(:fetch, backend, workspace, resolved, opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         :ok <- assert_remote_credentials(backend, repo, :fetch, opts),
         :ok <- backend.fetch(repo, remote_opts(opts)) do
      {:ok, "fetched #{remote_name(opts)}", %{action: :fetch}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:pull, backend, workspace, resolved, opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         :ok <- assert_remote_credentials(backend, repo, :pull, opts) do
      result = backend.pull(repo, remote_opts(opts))

      case result do
        :up_to_date -> {:ok, "already up to date", %{action: :pull, result: :up_to_date}}
        :fast_forward -> {:ok, "fast-forwarded", %{action: :pull, result: :fast_forward}}
        {:error, reason} -> format_error(reason)
      end
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:push, backend, workspace, resolved, opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         :ok <- assert_remote_credentials(backend, repo, :push, opts),
         :ok <- backend.push(repo, remote_opts(opts)) do
      {:ok, "pushed #{remote_name(opts)}", %{action: :push}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:remotes, backend, workspace, resolved, _opts) do
    with {:ok, repo} <- open(backend, resolved, workspace),
         {:ok, remotes} <- backend.remotes(repo) do
      {:ok, format_remotes(remotes), %{action: :remotes, remotes: remotes}}
    else
      {:error, reason} -> format_error(reason)
    end
  end

  defp do_run(:remote_add, backend, workspace, resolved, opts) do
    url = opts[:url]
    name = remote_name(opts)

    cond do
      not is_binary(url) or String.trim(url) == "" ->
        {:error, "url is required"}

      true ->
        with :ok <- assert_https_url(url),
             {:ok, repo} <- open(backend, resolved, workspace),
             :ok <- backend.remote_add(repo, name, url) do
          {:ok, "added remote #{name} #{url}", %{action: :remote_add, name: name, url: url}}
        else
          {:error, reason} -> format_error(reason)
        end
    end
  end

  defp do_run(:remote_set_url, backend, workspace, resolved, opts) do
    url = opts[:url]
    name = remote_name(opts)

    cond do
      not is_binary(url) or String.trim(url) == "" ->
        {:error, "url is required"}

      true ->
        with :ok <- assert_https_url(url),
             {:ok, repo} <- open(backend, resolved, workspace),
             :ok <- backend.remote_set_url(repo, name, url) do
          {:ok, "set #{name} to #{url}", %{action: :remote_set_url, name: name, url: url}}
        else
          {:error, reason} -> format_error(reason)
        end
    end
  end

  defp open(backend, path, workspace) do
    with {:ok, repo} <- backend.open(path, ceiling: exclusive_ceiling(workspace)),
         {:ok, workdir} <- backend.workdir(repo),
         :ok <- assert_inside(workdir, workspace) do
      {:ok, repo}
    end
  end

  # Discovery will not enter the exclusive ceiling while walking parents,
  # so a repo at the workspace root is still found.
  defp exclusive_ceiling(workspace) do
    parent = Path.dirname(workspace)
    if parent == workspace, do: workspace, else: parent
  end

  defp do_reset(backend, repo, workspace, opts) do
    cond do
      is_list(opts[:paths]) and opts[:paths] != [] ->
        with {:ok, paths} <- resolve_paths(backend, opts[:paths], workspace, repo),
             :ok <- backend.reset_paths(repo, paths) do
          {:ok, "unstaged #{Enum.join(paths, ", ")}"}
        end

      opts[:type] in [:soft, :mixed, :hard] ->
        target = opts[:target] || "HEAD"

        with :ok <- backend.reset(repo, opts[:type], target) do
          {:ok, "reset --#{opts[:type]} #{target}"}
        end

      true ->
        {:error, "reset requires paths or type=soft|mixed|hard"}
    end
  end

  defp identity(opts) do
    configured = Handbean.Git.Settings.identity()

    [
      name: opts[:name] || configured[:name] || @identity[:name],
      email: opts[:email] || configured[:email] || @identity[:email]
    ]
  end

  defp require_workspace(workspace) when is_binary(workspace) and workspace != "" do
    expanded = Path.expand(workspace)

    case Handbean.Security.PathValidator.canonicalize(expanded) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _} -> {:error, "working_directory is invalid"}
    end
  end

  defp require_workspace(_), do: {:error, "working_directory is required"}

  defp resolve_target(:clone, path, workspace), do: resolve_clone_dest(path, workspace)
  defp resolve_target(_action, path, workspace), do: resolve_dir(path, workspace)

  defp resolve_clone_dest(path, workspace) do
    with {:ok, resolved} <- Handbean.Workspace.resolve(path || ".", workspace),
         :ok <- assert_inside(resolved, workspace) do
      {:ok, resolved}
    end
  end

  defp resolve_dir(path, workspace) do
    with {:ok, resolved} <- Handbean.Workspace.resolve(path || ".", workspace),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(resolved) do
      {:ok, resolved}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, "git path must be a directory, got #{type}"}

      {:error, :enoent} ->
        {:error, "directory not found: #{path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "cannot stat git path: #{inspect(reason)}"}
    end
  end

  defp resolve_paths(backend, paths, workspace, repo) when is_list(paths) do
    with {:ok, workdir} <- backend.workdir(repo) do
      repo_path = Path.expand(workdir)

      result =
        Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
          case resolve_git_path(path, workspace, repo_path) do
            {:ok, rel} -> {:cont, {:ok, [rel | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        error -> error
      end
    end
  end

  defp resolve_paths(_, _, _, _), do: {:error, "paths must be a list"}

  defp resolve_git_path(path, workspace, repo_path) when is_binary(path) do
    with {:ok, resolved} <- Handbean.Workspace.resolve(path, workspace),
         :ok <- assert_inside(resolved, repo_path) do
      {:ok, Path.relative_to(resolved, repo_path)}
    end
  end

  defp resolve_git_path(_, _, _), do: {:error, "path must be a string"}

  defp assert_inside(path, root) do
    Handbean.Security.PathValidator.validate_within_workspace(path, root)
  end

  defp assert_https_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "only http(s) remotes are supported"}

      uri.userinfo not in [nil, ""] ->
        {:error, "credentials must not be embedded in the URL"}

      uri.host in [nil, ""] ->
        {:error, "url host is required"}

      true ->
        :ok
    end
  end

  defp assert_clone_credentials(backend, url, workspace, opts) do
    case credential_password(opts) do
      nil ->
        :ok

      _ ->
        with {:ok, endpoint} <- require_credential_endpoint(opts),
             {:ok, urls} <- clone_destinations(backend, url, workspace) do
          CredentialGuard.assert_https_destinations(urls, endpoint)
        end
    end
  end

  defp assert_remote_credentials(backend, repo, action, opts) do
    case credential_password(opts) do
      nil ->
        :ok

      _ ->
        with {:ok, endpoint} <- require_credential_endpoint(opts),
             {:ok, urls} <- remote_destinations(backend, repo, action, remote_name(opts)) do
          CredentialGuard.assert_https_destinations(urls, endpoint)
        end
    end
  end

  defp credential_password(opts) do
    password = opts[:password]
    if is_binary(password) and password != "", do: password, else: nil
  end

  defp require_credential_endpoint(opts) do
    endpoint = opts[:credential_endpoint]

    if is_binary(endpoint) and endpoint != "" do
      {:ok, endpoint}
    else
      {:error, CredentialGuard.mismatch_message()}
    end
  end

  defp clone_destinations(backend, url, workspace) do
    if backend == CLI do
      CLI.expand_clone_url(url, workspace)
    else
      {:ok, [url]}
    end
  end

  defp remote_destinations(backend, repo, action, name) do
    if backend == CLI do
      CLI.remote_action_urls(repo, name, action)
    else
      with {:ok, remotes} <- backend.remotes(repo) do
        case Enum.find(remotes, &(&1.name == name)) do
          nil -> {:error, "remote #{name} is not configured"}
          remote -> {:ok, [remote.url]}
        end
      end
    end
  end

  defp remote_name(opts), do: opts[:remote] || "origin"

  defp remote_opts(opts) do
    [remote: remote_name(opts)] ++ auth_opts(opts)
  end

  @doc false
  def auth_opts(opts) when is_list(opts) do
    Keyword.take(opts, [:username, :password, :credential_endpoint])
    |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
  end

  defp display(path, workspace), do: Handbean.Workspace.relative_path(path, workspace)

  defp format_status(%{branch: branch, entries: entries}) do
    header = "branch: #{format_branch(branch)}"

    body =
      case entries do
        [] ->
          "clean"

        list ->
          Enum.map_join(list, "\n", fn entry ->
            staged = format_kind(entry.staged)
            unstaged = format_kind(entry.unstaged)
            old = if entry[:old_path], do: " (from #{entry.old_path})", else: ""
            "#{staged}#{unstaged} #{entry.path}#{old}"
          end)
      end

    header <> "\n" <> body
  end

  defp format_branch(:unborn), do: "(unborn)"
  defp format_branch(:detached), do: "(detached)"
  defp format_branch(name) when is_binary(name), do: name
  defp format_branch(other), do: inspect(other)

  defp format_kind(nil), do: "."
  defp format_kind(:new), do: "A"
  defp format_kind(:modified), do: "M"
  defp format_kind(:deleted), do: "D"
  defp format_kind(:renamed), do: "R"
  defp format_kind(:typechange), do: "T"
  defp format_kind(:conflicted), do: "U"
  defp format_kind(:ignored), do: "!"
  defp format_kind(:unreadable), do: "?"
  defp format_kind(other) when is_atom(other), do: "?"

  defp format_log([]), do: "(no commits)"

  defp format_log(commits) do
    Enum.map_join(commits, "\n", fn commit ->
      author = commit.author[:name] || ""
      "#{short_oid(commit.oid)} #{commit.summary} (#{author})"
    end)
  end

  defp format_branches(branches) do
    Enum.map_join(branches, "\n", fn branch ->
      mark = if branch.current?, do: "* ", else: "  "
      mark <> branch.name
    end)
  end

  defp format_remotes([]), do: "(no remotes)"

  defp format_remotes(remotes) do
    Enum.map_join(remotes, "\n", fn remote ->
      "#{remote.name} #{remote.url}"
    end)
  end

  defp short_oid(oid) when is_binary(oid), do: String.slice(oid, 0, 7)
  defp short_oid(_), do: "???????"

  defp format_error({code, message}) when is_atom(code) and is_binary(message) do
    {:error, "#{code}: #{message}"}
  end

  defp format_error(reason) when is_binary(reason), do: {:error, reason}
  defp format_error(reason), do: {:error, inspect(reason)}
end
