defmodule Handbean.Tool.Builtin.Git do
  @moduledoc """
  Agent entry for Git history on hosts that inject a Git backend.

  Android/iOS hosts inject the ExGit/libgit2 backend at boot. Desktop hosts
  do not register this tool; their agents invoke the machine's Git through
  `bash`. HTTPS clone/fetch/push and fast-forward pull are allowed. After
  `init`, add an origin with `remote_add` then push. SSH is not.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Git

  @impl true
  def name, do: "git"

  @impl true
  def description do
    """
    Local Git history for the current workspace. Use after editing files so the user can review and roll back agent changes.

    Actions: init, status, diff, add, reset, commit, log, branches, create_branch, checkout, clone, fetch, pull, push, remotes, remote_add, remote_set_url.
    HTTP(S) remotes only. After init, remote_add an https GitHub URL then push. For private repositories, pass a configured credential name, never a password or PAT. Credentials require HTTPS at the actual destination after Git URL rewrites, including every push URL, and trust the configured hostname across all ports and repository paths. Paths stay inside the workspace. pull fast-forwards only and will not create a merge commit. A successful push sets upstream so the next pull can fast-forward. SSH is not supported. This tool is registered only when the host injects a Git backend; desktop agents use the machine's Git through bash.

    #{Handbean.Git.Settings.summarize()}
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: [
            "init",
            "status",
            "diff",
            "add",
            "reset",
            "commit",
            "log",
            "branches",
            "create_branch",
            "checkout",
            "clone",
            "fetch",
            "pull",
            "push",
            "remotes",
            "remote_add",
            "remote_set_url"
          ],
          description: "Git operation to run."
        },
        path: %{
          type: "string",
          description:
            "Workspace-relative or absolute repository directory. Defaults to the workspace root."
        },
        paths: %{
          type: "array",
          items: %{type: "string"},
          description:
            "For add/reset, paths to stage or unstage. Empty add stages the whole tree."
        },
        message: %{
          type: "string",
          description: "For commit, the commit message."
        },
        name: %{
          type: "string",
          description: "For create_branch, the local branch name."
        },
        target: %{
          type: "string",
          description: "For checkout, a local branch name or revision. For reset, a revision."
        },
        type: %{
          type: "string",
          enum: ["soft", "mixed", "hard"],
          description: "For reset of HEAD (not path unstage)."
        },
        mode: %{
          type: "string",
          enum: ["head", "worktree", "staged"],
          description:
            "For diff: HEAD-to-worktree (default), index-to-worktree, or HEAD-to-index."
        },
        from: %{
          type: "string",
          description: "For diff, the starting revision. Must be used together with to."
        },
        to: %{
          type: "string",
          description: "For diff, the ending revision. Must be used together with from."
        },
        limit: %{
          type: "integer",
          description: "For log, maximum commits to return. Default 20."
        },
        force: %{
          type: "boolean",
          description: "For checkout/create_branch, overwrite existing state.",
          default: false
        },
        url: %{
          type: "string",
          description:
            "For clone, remote_add, and remote_set_url: an http(s) URL. Do not embed credentials."
        },
        remote: %{
          type: "string",
          description:
            "For fetch/pull/push/remote_add/remote_set_url, remote name. Default origin."
        },
        credential: %{
          type: "string",
          description:
            "For clone/fetch/pull/push, an optional host-configured credential name. Never supply the secret itself."
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def max_result_chars, do: 40_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, _context)
      when is_map_key(input, "password") or is_map_key(input, "username") do
    {:error, "Use a host-configured credential name; raw Git credentials are not accepted"}
  end

  def execute(%{"action" => action} = input, context) when is_binary(action) do
    workspace =
      Handbean.Utils.SafeMap.get_any(context, :working_directory, "working_directory")

    with {:ok, action} <- parse_action(action),
         {:ok, opts} <- action_opts(action, input) do
      Git.perform(action, workspace, Map.get(input, "path", "."), opts)
    end
  end

  def execute(_input, _context), do: {:error, "action is required"}

  defp parse_action("init"), do: {:ok, :init}
  defp parse_action("status"), do: {:ok, :status}
  defp parse_action("diff"), do: {:ok, :diff}
  defp parse_action("add"), do: {:ok, :add}
  defp parse_action("reset"), do: {:ok, :reset}
  defp parse_action("commit"), do: {:ok, :commit}
  defp parse_action("log"), do: {:ok, :log}
  defp parse_action("branches"), do: {:ok, :branches}
  defp parse_action("create_branch"), do: {:ok, :create_branch}
  defp parse_action("checkout"), do: {:ok, :checkout}
  defp parse_action("clone"), do: {:ok, :clone}
  defp parse_action("fetch"), do: {:ok, :fetch}
  defp parse_action("pull"), do: {:ok, :pull}
  defp parse_action("push"), do: {:ok, :push}
  defp parse_action("remotes"), do: {:ok, :remotes}
  defp parse_action("remote_add"), do: {:ok, :remote_add}
  defp parse_action("remote_set_url"), do: {:ok, :remote_set_url}
  defp parse_action(other), do: {:error, "unsupported git action: #{other}"}

  defp action_opts(:add, input), do: {:ok, [paths: List.wrap(input["paths"])]}

  defp action_opts(:reset, input) do
    type =
      case input["type"] do
        "soft" -> :soft
        "mixed" -> :mixed
        "hard" -> :hard
        _ -> nil
      end

    {:ok, [paths: List.wrap(input["paths"]), type: type, target: input["target"]]}
  end

  defp action_opts(:commit, input), do: {:ok, [message: input["message"]]}

  defp action_opts(:diff, input) do
    from = input["from"]
    to = input["to"]
    range? = Map.has_key?(input, "from") or Map.has_key?(input, "to")

    cond do
      Map.has_key?(input, "target") ->
        {:error, "diff does not accept target; use from and to for a revision range"}

      valid_revision?(from) and valid_revision?(to) ->
        {:ok, [mode: {from, to}]}

      range? ->
        {:error, "diff requires non-empty from and to revisions"}

      true ->
        mode =
          case input["mode"] do
            "worktree" -> :worktree
            "staged" -> :staged
            _ -> :head
          end

        {:ok, [mode: mode]}
    end
  end

  defp action_opts(:log, input), do: {:ok, [limit: input["limit"] || 20]}

  defp action_opts(:create_branch, input) do
    {:ok, [name: input["name"], force: truthy?(input["force"])]}
  end

  defp action_opts(:checkout, input) do
    {:ok, [target: input["target"] || input["name"], force: truthy?(input["force"])]}
  end

  defp action_opts(:clone, input) do
    with {:ok, opts} <- remote_auth(input) do
      {:ok, Keyword.put(opts, :url, input["url"])}
    end
  end

  defp action_opts(action, input) when action in [:fetch, :pull, :push] do
    remote_auth(input)
  end

  defp action_opts(:remote_add, input) do
    {:ok, [url: input["url"], remote: input["remote"] || "origin"]}
  end

  defp action_opts(:remote_set_url, input) do
    {:ok, [url: input["url"], remote: input["remote"] || "origin"]}
  end

  defp action_opts(_action, _input), do: {:ok, []}

  defp remote_auth(input) do
    with {:ok, auth} <- Handbean.Git.Credentials.resolve(input["credential"]) do
      {:ok, Keyword.put(auth, :remote, input["remote"] || "origin")}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp valid_revision?(revision), do: is_binary(revision) and String.trim(revision) != ""
end
