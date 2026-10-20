defmodule Handbean.Git.CLI do
  @moduledoc """
  Host Git CLI backend.

  Invokes an argv list, never a shell string. Handbean identity and
  credentials are per-invocation: they are not written to Git config, URLs,
  command lines, or durable plaintext files.

  Priority for a call:

  1. Handbean identity (`Settings` / opts) via `-c user.name` / `user.email`
  2. Handbean HTTPS credentials via `GIT_ASKPASS` and the child environment
  3. User Git configuration for other keys, except hooks, credential helpers,
     GPG signing, and pager which this backend overrides so the call stays
     noninteractive
  4. Inherited `GIT_DIR` / `GIT_WORK_TREE` / `GIT_CONFIG*` /
     `GIT_CONFIG_PARAMETERS` / `GIT_SSH*` / credential-trace variables are
     cleared so the environment cannot redirect the repository or leak
     secrets. Ordinary diff disables external diff drivers and textconv.
  """

  @behaviour Handbean.Git.Backend

  alias Handbean.Git.CLI.{Detect, Exec}
  alias Handbean.Git.CredentialGuard

  @type repo :: {:cli, String.t()}

  @empty_tree_sha1 "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  @empty_tree_sha256 "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
  @diff_safety ["--no-ext-diff", "--no-textconv"]

  @impl true
  def available do
    case Detect.probe() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(path) do
    git_dir = Path.join(path, ".git")

    cond do
      File.exists?(git_dir) ->
        {:error, "repository already exists"}

      true ->
        with :ok <- git_ok(["init", "-b", "main", "--", path], cwd: parent_or_path(path)) do
          open(path, [])
        end
    end
  end

  @impl true
  def open(path, opts) do
    ceiling = Keyword.get(opts, :ceiling)
    env = ceiling_env(ceiling)

    result = git(["rev-parse", "--show-toplevel"], cwd: path, env: env)

    case result do
      {:ok, output} ->
        workdir = output |> String.trim() |> Path.expand()
        {:ok, {:cli, workdir}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def workdir({:cli, workdir}), do: {:ok, workdir}

  @impl true
  def status(repo) do
    with {:ok, output} <-
           git(
             ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
             cwd: cwd(repo)
           ) do
      {:ok, parse_status(output)}
    end
  end

  @doc false
  def read_head_file(repo, path) when is_binary(path), do: read_revision_file(repo, "HEAD", path)

  @doc false
  def read_revision_file(repo, revision, path)
      when is_binary(revision) and is_binary(path) do
    git(
      ["show", "--no-ext-diff", "--no-textconv", "--end-of-options", "#{revision}:./#{path}"],
      cwd: cwd(repo)
    )
  end

  @doc false
  def tracked_files(repo) do
    with {:ok, output} <- git(["ls-files", "-z"], cwd: cwd(repo)) do
      {:ok, output |> String.split(<<0>>, trim: true) |> MapSet.new()}
    end
  end

  @doc false
  def changed_paths(repo, from, to) when is_binary(from) and is_binary(to) do
    with {:ok, output} <-
           git(
             ["diff", "--name-only", "--no-renames", "-z"] ++
               @diff_safety ++
               ["--end-of-options", from, to],
             cwd: cwd(repo)
           ) do
      {:ok, String.split(output, <<0>>, trim: true)}
    end
  end

  @impl true
  def diff(repo, mode) do
    result = git(diff_args(mode), cwd: cwd(repo))

    case result do
      {:ok, output} ->
        {:ok, output}

      {:error, message} ->
        if no_head?(message) and default_head_diff?(mode) do
          unborn_head_diff(repo)
        else
          {:error, message}
        end
    end
  end

  @impl true
  def add(repo, paths) do
    args =
      if paths == [] do
        ["add", "-A", "--"]
      else
        ["add", "--"] ++ paths
      end

    git_ok(args, cwd: cwd(repo))
  end

  @impl true
  def reset(repo, type, target) when type in [:soft, :mixed, :hard] do
    git_ok(["reset", "--#{type}", "--end-of-options", target], cwd: cwd(repo))
  end

  @impl true
  def reset_paths(repo, paths) do
    git_ok(["reset", "--"] ++ paths, cwd: cwd(repo))
  end

  @impl true
  def commit(repo, message, opts) do
    name = opts[:name]
    email = opts[:email]

    cond do
      not is_binary(name) or name == "" or not is_binary(email) or email == "" ->
        {:error, "author name and email are required"}

      true ->
        extra = [{"user.name", name}, {"user.email", email}]

        with :ok <-
               git_ok(["commit", "--no-verify", "-m", message],
                 cwd: cwd(repo),
                 extra_config: extra
               ),
             {:ok, oid} <- git(["rev-parse", "HEAD"], cwd: cwd(repo)) do
          {:ok, String.trim(oid)}
        end
    end
  end

  @impl true
  def log(repo, opts) do
    limit = opts[:limit] || 20

    result =
      git(
        [
          "-c",
          "log.showSignature=false",
          "log",
          "--max-count=#{limit}",
          "--pretty=format:%H%x00%an%x00%ae%x00%at%x00%s%x00%b%x1e"
        ],
        cwd: cwd(repo)
      )

    case result do
      {:ok, output} ->
        {:ok, parse_log(output)}

      {:error, message} ->
        if no_head?(message), do: {:ok, []}, else: {:error, message}
    end
  end

  @impl true
  def branches(repo) do
    result =
      git(["for-each-ref", "--format=%(HEAD)%09%(refname:short)", "refs/heads"], cwd: cwd(repo))

    case result do
      {:ok, output} -> {:ok, parse_branches(output)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def create_branch(repo, name, opts) do
    args =
      if opts[:force] == true do
        ["branch", "-f", "--end-of-options", name]
      else
        ["branch", "--end-of-options", name]
      end

    git_ok(args, cwd: cwd(repo))
  end

  @impl true
  def checkout(repo, target, opts) do
    args =
      if opts[:force] == true do
        ["checkout", "-f", "--end-of-options", target]
      else
        ["checkout", "--end-of-options", target]
      end

    git_ok(args, cwd: cwd(repo))
  end

  @impl true
  def clone(url, path, opts) do
    with :ok <-
           git_ok(["clone", "--no-recurse-submodules", "--", url, path],
             cwd: parent_or_path(path),
             auth: opts
           ) do
      open(path, [])
    end
  end

  @impl true
  def fetch(repo, opts) do
    git_ok(["fetch", "--", remote_name(opts)], cwd: cwd(repo), auth: opts)
  end

  @impl true
  def pull(repo, opts) do
    remote = remote_name(opts)

    with :ok <- git_ok(["fetch", "--", remote], cwd: cwd(repo), auth: opts),
         {:ok, before} <- head_oid(repo),
         {:ok, target} <- pull_target(repo, remote),
         :ok <- git_ok(["merge", "--ff-only", "--end-of-options", target], cwd: cwd(repo)),
         {:ok, after_oid} <- head_oid(repo) do
      if before == after_oid do
        :up_to_date
      else
        :fast_forward
      end
    end
  end

  @impl true
  def push(repo, opts) do
    remote = remote_name(opts)

    case current_branch(repo) do
      {:ok, branch} ->
        git_ok(["push", "-u", "--", remote, branch], cwd: cwd(repo), auth: opts)

      {:error, _} ->
        git_ok(["push", "--", remote, "HEAD"], cwd: cwd(repo), auth: opts)
    end
  end

  @impl true
  def remotes(repo) do
    with {:ok, output} <- git(["remote", "-v"], cwd: cwd(repo)) do
      {:ok, parse_remotes(output)}
    end
  end

  @impl true
  def remote_add(repo, name, url) do
    git_ok(["remote", "add", "--", name, url], cwd: cwd(repo))
  end

  @impl true
  def remote_set_url(repo, name, url) do
    git_ok(["remote", "set-url", "--", name, url], cwd: cwd(repo))
  end

  defp cwd({:cli, workdir}), do: workdir

  defp parent_or_path(path) do
    parent = Path.dirname(path)
    if parent == path, do: path, else: parent
  end

  defp remote_name(opts), do: opts[:remote] || "origin"

  def head_oid(repo) do
    result = git(["rev-parse", "HEAD"], cwd: cwd(repo))

    case result do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _} = error -> error
    end
  end

  defp current_branch(repo) do
    result = git(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd(repo))

    case result do
      {:ok, output} ->
        name = String.trim(output)
        if name == "", do: {:error, "detached HEAD"}, else: {:ok, name}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def expand_clone_url(url, cwd) when is_binary(url) do
    case git(["ls-remote", "--get-url", "--", url], cwd: cwd) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:error, CredentialGuard.mismatch_message()}
          expanded -> {:ok, [expanded]}
        end

      {:error, _} ->
        {:error, "could not resolve Git credential destination"}
    end
  end

  @doc false
  def remote_action_urls(repo, name, action) when action in [:fetch, :pull, :push] do
    args =
      case action do
        :push -> ["remote", "get-url", "--push", "--all", "--", name]
        _ -> ["remote", "get-url", "--all", "--", name]
      end

    case git(args, cwd: cwd(repo)) do
      {:ok, output} ->
        urls =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if urls == [] do
          {:error, "remote #{name} is not configured"}
        else
          {:ok, urls}
        end

      {:error, message} ->
        down = String.downcase(message)

        if String.contains?(down, "no such remote") or String.contains?(down, "not found") do
          {:error, "remote #{name} is not configured"}
        else
          {:error, "could not resolve Git credential destination"}
        end
    end
  end

  defp diff_args(:worktree), do: ["diff"] ++ @diff_safety
  defp diff_args(:staged), do: ["diff"] ++ @diff_safety ++ ["--cached"]

  defp diff_args({from, to}) when is_binary(from) and is_binary(to) do
    ["diff"] ++ @diff_safety ++ ["--end-of-options", from, to]
  end

  defp diff_args(_mode), do: ["diff"] ++ @diff_safety ++ ["HEAD"]

  defp default_head_diff?(mode), do: mode not in [:worktree, :staged] and not is_tuple(mode)

  defp unborn_head_diff(repo) do
    with {:ok, empty} <- empty_tree_oid(repo) do
      git(["diff"] ++ @diff_safety ++ ["--end-of-options", empty], cwd: cwd(repo))
    end
  end

  defp empty_tree_oid(repo) do
    case git(["rev-parse", "--show-object-format"], cwd: cwd(repo)) do
      {:ok, output} ->
        case String.trim(output) do
          "sha256" -> {:ok, @empty_tree_sha256}
          _ -> {:ok, @empty_tree_sha1}
        end

      {:error, _} ->
        {:ok, @empty_tree_sha1}
    end
  end

  defp pull_target(repo, remote) do
    case current_branch(repo) do
      {:ok, branch} ->
        if upstream_for_remote?(repo, remote) do
          {:ok, "@{u}"}
        else
          ref = "#{remote}/#{branch}"

          case git(["rev-parse", "--quiet", "--verify", "--end-of-options", ref], cwd: cwd(repo)) do
            {:ok, _} -> {:ok, ref}
            {:error, _} -> {:error, "no upstream configured for pull"}
          end
        end

      {:error, _} ->
        {:error, "no upstream configured for pull"}
    end
  end

  defp upstream_for_remote?(repo, remote) do
    case git(["rev-parse", "--abbrev-ref", "@{u}"], cwd: cwd(repo)) do
      {:ok, output} ->
        upstream = String.trim(output)
        upstream != "" and String.starts_with?(upstream, remote <> "/")

      {:error, _} ->
        false
    end
  end

  defp git_ok(args, opts) do
    case git(args, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp git(args, opts) do
    with {:ok, %{executable: executable}} <- Detect.probe(),
         {:ok, auth_env} <- auth_env(opts[:auth]) do
      secrets = auth_secrets(opts[:auth])
      env = Keyword.get(opts, :env, []) ++ auth_env ++ default_env()
      cwd = opts[:cwd]

      timeout =
        Keyword.get(opts, :timeout) || Application.get_env(:handbean, :git_timeout_ms, 60_000)

      argv = git_config_args(opts) ++ args

      result =
        Exec.run(executable, argv,
          cwd: cwd,
          env: env,
          timeout: timeout,
          secrets: secrets,
          executor: opts[:executor]
        )

      case result do
        {:ok, _output, %{timed_out: true}} ->
          {:error, "Git timed out after #{timeout}ms"}

        {:ok, output, %{exit_code: 0}} ->
          {:ok, output}

        {:ok, output, %{exit_code: code}} ->
          {:error, format_exit(code, output)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp git_config_args(opts) do
    hooks = Application.app_dir(:handbean, "priv/git-empty-hooks")

    base = [
      "-c",
      "core.fsmonitor=false",
      "-c",
      "core.untrackedCache=false",
      "-c",
      "core.hooksPath=#{hooks}",
      "-c",
      "credential.helper=",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "advice.detachedHead=false",
      "-c",
      "core.quotepath=false"
    ]

    extra =
      Enum.flat_map(Keyword.get(opts, :extra_config, []), fn {key, value} ->
        ["-c", "#{key}=#{value}"]
      end)

    auth_config =
      case opts[:auth] do
        auth when is_list(auth) ->
          if is_binary(auth[:password]) and auth[:password] != "" do
            ["-c", "http.followRedirects=false"]
          else
            []
          end

        _ ->
          []
      end

    base ++ extra ++ auth_config
  end

  defp default_env do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_OPTIONAL_LOCKS", "0"},
      {"GIT_LITERAL_PATHSPECS", "1"},
      {"GCM_INTERACTIVE", "never"},
      {"LC_ALL", "C"},
      {"LANG", "C"}
    ]
  end

  defp ceiling_env(nil), do: []

  defp ceiling_env(ceiling) when is_binary(ceiling) do
    [{"GIT_CEILING_DIRECTORIES", Path.expand(ceiling)}]
  end

  defp auth_env(nil), do: {:ok, []}

  defp auth_env(opts) when is_list(opts) do
    password = opts[:password]

    cond do
      not (is_binary(password) and password != "") ->
        {:ok, []}

      true ->
        with {:ok, host} <- CredentialGuard.host_from_endpoint(opts[:credential_endpoint]),
             {:ok, askpass} <- askpass_script() do
          username =
            if is_binary(opts[:username]) and opts[:username] != "",
              do: opts[:username],
              else: "x-access-token"

          {:ok,
           [
             {"HANDBEAN_GIT_USERNAME", username},
             {"HANDBEAN_GIT_PASSWORD", password},
             {"HANDBEAN_GIT_CREDENTIAL_HOST", host},
             {"GIT_ASKPASS", askpass},
             {"GIT_ASKPASS_REQUIRE", "force"}
           ]}
        else
          {:error, _} = error -> error
        end
    end
  end

  defp askpass_script do
    script = Application.app_dir(:handbean, "priv/git-askpass.sh")

    case File.stat(script) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0 do
          {:ok, script}
        else
          {:error, "Git askpass helper is not executable"}
        end

      _ ->
        {:error, "Git askpass helper is missing"}
    end
  end

  defp auth_secrets(nil), do: []

  defp auth_secrets(opts) when is_list(opts) do
    [opts[:password], opts[:username]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp format_exit(code, output) do
    trimmed = String.trim(output)

    if trimmed == "" do
      "Git exited with code #{code}"
    else
      "#{trimmed}"
    end
  end

  defp no_head?(message) when is_binary(message) do
    down = String.downcase(message)

    String.contains?(down, "unknown revision") or
      String.contains?(down, "bad revision") or
      String.contains?(down, "ambiguous argument 'head'") or
      String.contains?(down, "does not have any commits") or
      String.contains?(down, "needed a single revision")
  end

  defp parse_status(output) do
    records = nul_records(output)
    %{branch: parse_branch(records), entries: parse_status_entries(records, []) |> Enum.reverse()}
  end

  defp parse_branch(records) do
    oid =
      Enum.find_value(records, fn record ->
        if String.starts_with?(record, "# branch.oid "),
          do: String.trim_leading(record, "# branch.oid ")
      end)

    head =
      Enum.find_value(records, fn record ->
        if String.starts_with?(record, "# branch.head "),
          do: String.trim_leading(record, "# branch.head ")
      end)

    cond do
      oid == "(initial)" -> :unborn
      head == "(detached)" -> :detached
      is_binary(head) and head != "" -> head
      true -> :unborn
    end
  end

  defp parse_status_entries([], acc), do: acc

  defp parse_status_entries([record | rest], acc) do
    cond do
      String.starts_with?(record, "#") ->
        parse_status_entries(rest, acc)

      String.starts_with?(record, "1 ") ->
        parse_status_entries(rest, [ordinary_entry(record) | acc])

      String.starts_with?(record, "2 ") ->
        {orig, rest} =
          case rest do
            [next | tail] -> {next, tail}
            [] -> {nil, []}
          end

        parse_status_entries(rest, [rename_entry(record, orig) | acc])

      String.starts_with?(record, "u ") ->
        parse_status_entries(rest, [unmerged_entry(record) | acc])

      String.starts_with?(record, "? ") ->
        path = String.trim_leading(record, "? ")
        parse_status_entries(rest, [%{path: path, staged: nil, unstaged: :new} | acc])

      String.starts_with?(record, "! ") ->
        path = String.trim_leading(record, "! ")
        parse_status_entries(rest, [%{path: path, staged: nil, unstaged: :ignored} | acc])

      record == "" ->
        parse_status_entries(rest, acc)

      true ->
        parse_status_entries(rest, acc)
    end
  end

  defp ordinary_entry(record) do
    xy = String.slice(record, 2, 2)
    path = status_path(record)
    %{path: path, staged: kind(String.at(xy, 0)), unstaged: kind(String.at(xy, 1))}
  end

  defp rename_entry(record, orig) do
    xy = String.slice(record, 2, 2)
    path = status_path(record)

    %{
      path: path,
      staged: kind(String.at(xy, 0)),
      unstaged: kind(String.at(xy, 1)),
      old_path: orig
    }
  end

  defp unmerged_entry(record) do
    path = status_path(record)
    %{path: path, staged: :conflicted, unstaged: :conflicted}
  end

  defp status_path(record) do
    parts_count =
      cond do
        String.starts_with?(record, "2 ") -> 10
        String.starts_with?(record, "u ") -> 11
        true -> 9
      end

    case String.split(record, " ", parts: parts_count) do
      parts when length(parts) >= parts_count -> List.last(parts)
      parts -> List.last(parts) || ""
    end
  end

  defp kind("."), do: nil
  defp kind(" "), do: nil
  defp kind("M"), do: :modified
  defp kind("A"), do: :new
  defp kind("D"), do: :deleted
  defp kind("R"), do: :renamed
  defp kind("C"), do: :renamed
  defp kind("T"), do: :typechange
  defp kind("U"), do: :conflicted
  defp kind("?"), do: :new
  defp kind("!"), do: :ignored
  defp kind(_), do: nil

  defp parse_log(output) do
    output
    |> String.split("\x1e", trim: true)
    |> Enum.flat_map(fn record ->
      parts = String.split(record, "\0")

      case parts do
        [oid, name, email, time, summary | body_parts] ->
          body = Enum.join(body_parts, "\0") |> String.trim_trailing()
          message = String.trim_trailing(summary <> "\n\n" <> body)

          time_unix =
            case Integer.parse(time) do
              {int, _} -> int
              :error -> 0
            end

          [
            %{
              oid: String.trim(oid),
              summary: summary,
              message: message,
              author: %{name: name, email: email, time: time_unix}
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp parse_branches(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {mark, name} =
        case String.split(line, "\t", parts: 2) do
          [head, ref] -> {head, ref}
          [ref] -> {"", ref}
        end

      %{name: name, current?: String.trim(mark) == "*"}
    end)
  end

  defp parse_remotes(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case String.split(line, "\t") do
        [name, rest] ->
          url = rest |> String.replace(~r/ \((fetch|push)\)$/, "") |> String.trim()

          if Enum.any?(acc, &(&1.name == name)) do
            acc
          else
            [%{name: name, url: url} | acc]
          end

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp nul_records(output) do
    output
    |> String.split("\0")
    |> Enum.reject(&(&1 == ""))
  end
end
