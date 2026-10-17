defmodule Handbeam.WorkspaceStore do
  @moduledoc """
  Versioned JSON storage for workspace policy identities.

  One physical Git repository owns one workspace record. Linked worktrees are
  checkout selections under that workspace and are not persisted as separate
  workspaces.
  """

  require Logger

  alias Handbeam.{RepoIdentity, WorkspaceSettings}

  @default_storage "~/.handbeam/workspaces.json"
  @storage_version 2
  @dangerous_roots ["/", "/etc", "/System", "/bin", "/sbin", "/usr", "/var"]
  @required_fields ~w(id name kind repo_key path default_checkout_path default added_at last_opened_at)

  @spec storage_path() :: String.t()
  def storage_path do
    env = System.get_env("HANDBEAM_WORKSPACES_FILE")

    path =
      if is_binary(env) and env != "",
        do: env,
        else: Application.get_env(:handbeam, :workspaces_file) || @default_storage

    Handbeam.Home.expand(path)
  end

  @spec ensure_default!() :: {:ok, map()} | {:error, term()}
  def ensure_default! do
    path = storage_path()
    with_storage_lock(path, fn -> ensure_default(path) end)
  end

  defp ensure_default(path) do
    case read_storage(path) do
      {:ok, data} ->
        ensure_default_in_storage(path, data)

      {:error, :not_found} ->
        root = Handbeam.Workspace.default_root()

        with :ok <- File.mkdir_p(root) do
          workspace = build_default_workspace(root)
          data = empty_storage() |> Map.put("workspaces", [workspace])

          with :ok <- File.mkdir_p(Path.dirname(path)),
               :ok <- write_storage(path, data),
               :ok <- prepare_default_workspace(root) do
            {:ok, workspace}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_default_in_storage(path, data) do
    workspaces = data["workspaces"]
    root = canonical_default_root()

    case Enum.find_index(workspaces, &(&1["default"] == true)) do
      nil ->
        workspace = build_default_workspace(root)
        updated = Map.put(data, "workspaces", [workspace | workspaces])

        with :ok <- File.mkdir_p(root),
             :ok <- write_storage(path, updated),
             :ok <- prepare_default_workspace(root) do
          {:ok, workspace}
        end

      index ->
        existing = Enum.at(workspaces, index)

        corrected =
          existing
          |> Map.put("kind", "directory")
          |> Map.put("repo_key", root)
          |> Map.put("path", root)
          |> Map.put("default_checkout_path", root)

        updated = Map.put(data, "workspaces", List.replace_at(workspaces, index, corrected))

        with :ok <- File.mkdir_p(root),
             :ok <- maybe_write_changed(path, data, updated),
             :ok <- prepare_default_workspace(root) do
          {:ok, corrected}
        end
    end
  end

  defp canonical_default_root do
    Handbeam.Workspace.default_root()
    |> Path.expand()
    |> Handbeam.Security.PathValidator.resolve_symlink()
  end

  defp prepare_default_workspace(root), do: WorkspaceSettings.ensure_owner_file(root)

  @doc "List workspaces, retaining the historical list-only API."
  @spec list() :: [map()]
  def list do
    case list_result() do
      {:ok, workspaces} ->
        workspaces

      {:error, :not_found} ->
        []

      {:error, reason} ->
        Logger.warning("[WorkspaceStore] cannot load workspaces: #{inspect(reason)}")
        []
    end
  end

  @doc "Read workspaces without collapsing format or corruption errors."
  @spec list_result() :: {:ok, [map()]} | {:error, term()}
  def list_result do
    case read_storage(storage_path()) do
      {:ok, data} -> {:ok, data["workspaces"]}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Add a selected directory and return its owning workspace."
  @spec add(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add(raw_path, opts \\ []) do
    with {:ok, workspace, _checkout_path} <- add_selection(raw_path, opts) do
      {:ok, workspace}
    end
  end

  @doc "Add a selected directory while preserving the selected checkout context."
  @spec add_selection(String.t(), keyword()) ::
          {:ok, map(), String.t()} | {:error, term()}
  def add_selection(raw_path, opts \\ []) do
    with {:ok, identity} <- resolve_identity(raw_path),
         :ok <- validate_not_dangerous(identity.checkout_path),
         :ok <- validate_not_dangerous(identity.workspace_path) do
      path = storage_path()
      with_storage_lock(path, fn -> add_workspace(path, identity, opts) end)
    end
  end

  defp resolve_identity(path) do
    case RepoIdentity.resolve(path) do
      {:error, :not_found} -> {:error, "Path does not exist: #{Path.expand(path)}"}
      {:error, :not_directory} -> {:error, "Path must be a directory"}
      {:error, :unreadable} -> {:error, "Cannot read directory"}
      result -> result
    end
  end

  defp add_workspace(path, identity, opts) do
    with {:ok, data} <- load_storage(path) do
      workspaces = data["workspaces"]

      case directory_candidate(workspaces, identity.checkout_path) do
        {index, %{"kind" => "directory"} = workspace} when identity.kind == :git ->
          upgrade_directory_workspace(path, data, index, workspace, identity, opts)

        _other ->
          case Enum.find_index(workspaces, &(&1["repo_key"] == identity.repo_key)) do
            nil -> create_workspace(path, data, identity, opts)
            index -> touch_selected_workspace(path, data, index, identity, opts)
          end
      end
    end
  end

  defp directory_candidate(workspaces, checkout_path) do
    case Enum.find_index(workspaces, fn workspace ->
           workspace["kind"] == "directory" and
             checkout_path in [workspace["path"], workspace["default_checkout_path"]]
         end) do
      nil -> nil
      index -> {index, Enum.at(workspaces, index)}
    end
  end

  defp create_workspace(path, data, identity, opts) do
    now = now_iso8601()

    workspace = %{
      "id" => generate_id(),
      "name" => Keyword.get(opts, :name, Path.basename(identity.workspace_path)),
      "kind" => Atom.to_string(identity.kind),
      "repo_key" => identity.repo_key,
      "path" => identity.workspace_path,
      "default_checkout_path" => identity.checkout_path,
      "default" => false,
      "added_at" => now,
      "last_opened_at" => now
    }

    updated = Map.update!(data, "workspaces", &(&1 ++ [workspace]))

    with :ok <- write_storage(path, updated),
         :ok <- WorkspaceSettings.ensure_owner_file(identity.workspace_path),
         :ok <- maybe_configure_builtin_memory(identity.workspace_path, opts) do
      {:ok, workspace, identity.checkout_path}
    end
  end

  defp touch_selected_workspace(path, data, index, identity, opts) do
    workspace =
      data["workspaces"]
      |> Enum.at(index)
      |> Map.put("last_opened_at", now_iso8601())
      |> maybe_set_default_checkout(identity.checkout_path, opts)

    updated = Map.put(data, "workspaces", List.replace_at(data["workspaces"], index, workspace))

    with :ok <- write_storage(path, updated),
         :ok <- WorkspaceSettings.ensure_owner_file(workspace["path"]),
         :ok <- maybe_configure_builtin_memory(workspace["path"], opts) do
      {:ok, workspace, identity.checkout_path}
    end
  end

  defp maybe_set_default_checkout(workspace, checkout_path, opts) do
    if Keyword.get(opts, :set_default_checkout, false),
      do: Map.put(workspace, "default_checkout_path", checkout_path),
      else: workspace
  end

  defp upgrade_directory_workspace(path, data, index, workspace, identity, opts) do
    conflict =
      Enum.find(data["workspaces"], fn candidate ->
        candidate["id"] != workspace["id"] and candidate["repo_key"] == identity.repo_key
      end)

    if conflict do
      {:error, :workspace_repo_conflict}
    else
      updated_workspace =
        workspace
        |> Map.put("kind", "git")
        |> Map.put("repo_key", identity.repo_key)
        |> Map.put("path", identity.workspace_path)
        |> Map.put("last_opened_at", now_iso8601())
        |> preserve_valid_default_checkout(identity)
        |> maybe_set_default_checkout(identity.checkout_path, opts)

      updated =
        Map.put(data, "workspaces", List.replace_at(data["workspaces"], index, updated_workspace))

      with :ok <-
             WorkspaceSettings.prepare_owner_change(workspace["path"], identity.workspace_path),
           :ok <- write_storage(path, updated),
           :ok <- maybe_configure_builtin_memory(identity.workspace_path, opts) do
        {:ok, updated_workspace, identity.checkout_path}
      end
    end
  end

  defp preserve_valid_default_checkout(workspace, identity) do
    default_checkout = workspace["default_checkout_path"] || workspace["path"]

    if is_binary(default_checkout) and File.dir?(default_checkout) do
      Map.put(workspace, "default_checkout_path", default_checkout)
    else
      Map.put(workspace, "default_checkout_path", identity.checkout_path)
    end
  end

  @doc "Refresh directory/Git identity at a safe lifecycle boundary."
  @spec refresh_identity(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_identity(id) when is_binary(id) do
    path = storage_path()

    with_storage_lock(path, fn ->
      with {:ok, data} <- load_storage(path),
           index when is_integer(index) <- Enum.find_index(data["workspaces"], &(&1["id"] == id)),
           workspace <- Enum.at(data["workspaces"], index),
           selected when is_binary(selected) <-
             workspace["default_checkout_path"] || workspace["path"],
           {:ok, identity} <- RepoIdentity.resolve(selected) do
        refresh_workspace(path, data, index, workspace, identity)
      else
        nil -> {:error, :not_found}
        _ -> {:error, :not_found}
      end
    end)
  end

  defp refresh_workspace(
         path,
         data,
         index,
         %{"kind" => "directory"} = workspace,
         %{kind: :git} = identity
       ) do
    case upgrade_directory_workspace(path, data, index, workspace, identity, []) do
      {:ok, refreshed, _checkout} -> {:ok, refreshed}
      error -> error
    end
  end

  defp refresh_workspace(
         path,
         data,
         index,
         %{"kind" => "git"} = workspace,
         %{kind: :directory} = identity
       ) do
    cond do
      File.exists?(workspace["repo_key"]) ->
        {:ok, workspace}

      identity.workspace_path != workspace["path"] ->
        {:ok, workspace}

      Enum.any?(data["workspaces"], fn candidate ->
        candidate["id"] != workspace["id"] and candidate["repo_key"] == identity.repo_key
      end) ->
        {:error, :workspace_repo_conflict}

      true ->
        refreshed =
          workspace
          |> Map.put("kind", "directory")
          |> Map.put("repo_key", identity.repo_key)
          |> Map.put("path", identity.workspace_path)

        updated =
          Map.put(data, "workspaces", List.replace_at(data["workspaces"], index, refreshed))

        with :ok <- write_storage(path, updated), do: {:ok, refreshed}
    end
  end

  defp refresh_workspace(path, data, index, workspace, identity) do
    touched = Map.put(workspace, "last_opened_at", now_iso8601())
    updated = Map.put(data, "workspaces", List.replace_at(data["workspaces"], index, touched))

    if workspace["repo_key"] == identity.repo_key do
      with :ok <- write_storage(path, updated), do: {:ok, touched}
    else
      {:error, :workspace_identity_changed}
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(id) do
    with {:ok, workspaces} <- list_result() do
      case Enum.find(workspaces, &(&1["id"] == id)) do
        nil -> {:error, :not_found}
        workspace -> {:ok, workspace}
      end
    end
  end

  @spec get_by_path(String.t()) :: {:ok, map()} | {:error, term()}
  def get_by_path(path) when is_binary(path) do
    with {:ok, workspaces} <- list_result_or_empty(),
         {:ok, canonical} <- canonical_lookup_path(path) do
      direct =
        Enum.find(workspaces, fn workspace ->
          canonical in [workspace["path"], workspace["default_checkout_path"]]
        end)

      case direct do
        nil -> get_by_resolved_identity(workspaces, path)
        workspace -> {:ok, workspace}
      end
    end
  end

  def get_by_path(_path), do: {:error, :not_found}

  defp list_result_or_empty do
    case list_result() do
      {:error, :not_found} -> {:ok, []}
      result -> result
    end
  end

  defp canonical_lookup_path(path) do
    case Handbeam.Security.PathValidator.canonicalize(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:ok, Path.expand(path)}
    end
  end

  defp get_by_resolved_identity(workspaces, path) do
    with {:ok, identity} <- RepoIdentity.resolve(path) do
      case Enum.find(workspaces, &(&1["repo_key"] == identity.repo_key)) do
        nil -> {:error, :not_found}
        workspace -> {:ok, workspace}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @spec touch(String.t()) :: {:ok, map()} | {:error, term()}
  def touch(id) do
    path = storage_path()

    with_storage_lock(path, fn ->
      update_workspace(path, id, &Map.put(&1, "last_opened_at", now_iso8601()))
    end)
  end

  @spec rename(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rename(id, name) when is_binary(id) and is_binary(name) do
    with {:ok, normalized} <- normalize_name(name) do
      path = storage_path()

      with_storage_lock(path, fn ->
        update_workspace(path, id, &Map.put(&1, "name", normalized))
      end)
    end
  end

  defp update_workspace(path, id, fun) do
    with {:ok, data} <- load_storage(path) do
      case Enum.find_index(data["workspaces"], &(&1["id"] == id)) do
        nil ->
          {:error, :not_found}

        index ->
          updated_workspace = data["workspaces"] |> Enum.at(index) |> fun.()

          updated =
            Map.put(
              data,
              "workspaces",
              List.replace_at(data["workspaces"], index, updated_workspace)
            )

          with :ok <- write_storage(path, updated), do: {:ok, updated_workspace}
      end
    end
  end

  @doc false
  def normalize_name(name) when is_binary(name) do
    normalized =
      name
      |> String.replace(~r/[\r\n\t]+/u, " ")
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    cond do
      normalized == "" -> {:error, :empty}
      String.length(normalized) > 80 -> {:error, :too_long}
      true -> {:ok, normalized}
    end
  end

  @spec remove(String.t()) :: {:ok, map()} | {:error, term()}
  def remove(id) when is_binary(id) do
    path = storage_path()

    case with_storage_lock(path, fn -> remove_workspace(path, id) end) do
      {:ok, workspace} = result ->
        _ = Handbeam.CodeIndex.delete_workspace(workspace["path"], workspace["id"])
        result

      error ->
        error
    end
  end

  defp remove_workspace(path, id) do
    with {:ok, data} <- load_storage(path) do
      case Enum.find(data["workspaces"], &(&1["id"] == id)) do
        nil ->
          {:error, :not_found}

        %{"default" => true} ->
          {:error, :default_workspace}

        workspace ->
          updated =
            Map.put(data, "workspaces", Enum.reject(data["workspaces"], &(&1["id"] == id)))

          with :ok <- write_storage(path, updated), do: {:ok, workspace}
      end
    end
  end

  defp build_default_workspace(root) do
    now = now_iso8601()

    %{
      "id" => "default",
      "name" => "My Workspace",
      "kind" => "directory",
      "repo_key" => root,
      "path" => root,
      "default_checkout_path" => root,
      "default" => true,
      "added_at" => now,
      "last_opened_at" => now
    }
  end

  defp validate_not_dangerous(path) do
    canonical = Handbeam.Security.PathValidator.resolve_symlink(Path.expand(path))

    dangerous? =
      Enum.any?(@dangerous_roots, fn root ->
        Handbeam.Security.PathValidator.resolve_symlink(Path.expand(root)) == canonical
      end)

    if dangerous? do
      {:error, "Path #{path} cannot be added as a workspace"}
    else
      :ok
    end
  end

  defp maybe_configure_builtin_memory(path, opts) do
    if Keyword.get(opts, :builtin_memory_enabled, true) == false,
      do: WorkspaceSettings.update_builtin_memory_enabled(path, false),
      else: :ok
  end

  defp generate_id do
    ts = System.os_time(:millisecond)
    random = rem(System.unique_integer([:positive]), 100_000)
    "ws_#{ts}_#{random}"
  end

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp empty_storage, do: %{"version" => @storage_version, "workspaces" => []}

  defp read_storage(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_storage(content)

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[WorkspaceStore] Error reading #{path}: #{inspect(reason)}")
        {:error, :corrupted}
    end
  end

  defp decode_storage(content) do
    case Handbeam.JSON.decode(content) do
      {:ok, %{"version" => @storage_version, "workspaces" => workspaces} = data}
      when is_list(workspaces) ->
        if Enum.all?(workspaces, &valid_workspace?/1), do: {:ok, data}, else: {:error, :corrupted}

      {:ok, %{"workspaces" => workspaces}} when is_list(workspaces) ->
        {:error, :workspace_format_outdated}

      {:ok, %{"version" => version}} when version != @storage_version ->
        {:error, :workspace_format_outdated}

      _ ->
        {:error, :corrupted}
    end
  end

  defp valid_workspace?(workspace) when is_map(workspace) do
    Enum.all?(@required_fields, &Map.has_key?(workspace, &1)) and
      workspace["kind"] in ["git", "directory"] and
      Enum.all?(
        ~w(id name repo_key path default_checkout_path added_at last_opened_at),
        fn field ->
          is_binary(workspace[field]) and workspace[field] != ""
        end
      ) and is_boolean(workspace["default"])
  end

  defp valid_workspace?(_workspace), do: false

  defp load_storage(path) do
    case read_storage(path) do
      {:ok, data} -> {:ok, data}
      {:error, :not_found} -> {:ok, empty_storage()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def normalize_transaction_result(:aborted), do: {:error, :lock_aborted}
  def normalize_transaction_result(result), do: result

  defp with_storage_lock(path, fun) when is_function(fun, 0) do
    resource = {:handbeam_workspace_store, Handbeam.StorageLock.canonical_path(path)}

    {resource, self()}
    |> :global.trans(fun, [node()])
    |> normalize_transaction_result()
  end

  defp maybe_write_changed(_path, data, data), do: :ok
  defp maybe_write_changed(path, _old, updated), do: write_storage(path, updated)

  defp write_storage(path, data) do
    tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Handbeam.JSON.encode(data, pretty: true),
         :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(tmp_path)
        Logger.error("[WorkspaceStore] Error writing storage: #{inspect(reason)}")
        error
    end
  end
end
