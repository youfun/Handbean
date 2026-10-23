defmodule HandbeanWeb.WorkspaceLive.ConversationSwitching.CheckoutMetadata do
  @moduledoc false

  alias HandbeanWeb.WorkspaceLive.ConversationState

  @cache_owner HandbeanWeb.WorkspaceLive.ConversationSwitching

  def new_conversation_projects(workspaces) when is_list(workspaces) do
    Enum.map(workspaces, fn ws ->
      %{
        id: ws["id"],
        name: ws["name"] || ws["id"],
        path: ws["path"],
        checkouts: checkouts_for(ws)
      }
    end)
  end

  def new_conversation_projects(_workspaces), do: []

  def checkouts_for(ws) do
    root = ws["path"] || ws["default_checkout_path"]

    case Handbean.RepoIdentity.list_checkouts(root) do
      {:ok, checkouts} -> checkouts
      {:error, _reason} -> []
    end
  end

  @doc "Folder, live branch, and absolute checkout path shown on conversation hover."
  def hover_context(conversation) when is_map(conversation) do
    path = ConversationState.conv_value(conversation, "checkout_path", nil)
    available? = is_binary(path) and path != "" and File.dir?(path)

    %{
      folder: if(is_binary(path) and path != "", do: Path.basename(path)),
      branch: if(available?, do: hover_branch(path)),
      path: path,
      available: available?
    }
  end

  def hover_context(_conversation),
    do: %{folder: nil, branch: nil, path: nil, available: false}

  @doc "Git remote repository name for a workspace path, e.g. `Handbean`."
  def repo_name(path) when is_binary(path) and path != "" do
    key = {path, cache_bucket()}

    case :persistent_term.get({@cache_owner, :repo, key}, :miss) do
      :miss ->
        name = read_repo_name(path)
        :persistent_term.put({@cache_owner, :repo, key}, name)
        name

      name ->
        name
    end
  end

  def repo_name(_path), do: nil

  defp hover_branch(path) when is_binary(path) and path != "" do
    key = {path, cache_bucket()}

    case :persistent_term.get({@cache_owner, :branch, key}, :miss) do
      :miss ->
        branch = read_branch(path)
        :persistent_term.put({@cache_owner, :branch, key}, branch)
        branch

      branch ->
        branch
    end
  end

  defp hover_branch(_path), do: nil

  defp cache_bucket do
    div(System.system_time(:second), 30)
  end

  defp read_repo_name(path) do
    case Handbean.Git.CLI.remotes({:cli, path}) do
      {:ok, remotes} ->
        remotes
        |> Enum.find(&(&1.name == "origin"))
        |> Kernel.||(List.first(remotes))
        |> then(&repo_name_from_remote/1)

      _ ->
        nil
    end
  end

  defp repo_name_from_remote(nil), do: nil
  defp repo_name_from_remote(%{url: url}), do: repo_name_from_url(url)

  defp repo_name_from_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace(~r/\.git$/, "")
    |> String.split(["/", ":"])
    |> List.last()
    |> case do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp repo_name_from_url(_url), do: nil

  defp read_branch(path) do
    case Handbean.Git.CLI.branches({:cli, path}) do
      {:ok, branches} ->
        case Enum.find(branches, & &1.current?) do
          %{name: name} when is_binary(name) and name != "" -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
