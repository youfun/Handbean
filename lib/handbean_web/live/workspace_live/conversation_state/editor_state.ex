defmodule HandbeanWeb.WorkspaceLive.ConversationState.EditorState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Handbean.Security.PathValidator

  def select_file(socket, path, workspace_root, sync) do
    open(socket, path, workspace_root, :user, sync)
  end

  def select(socket, path, workspace_root, sync) do
    with true <- available?(socket),
         true <- is_binary(path) and Path.type(path) == :relative,
         {:ok, relative} <- relative_path(path, workspace_root),
         true <- Enum.any?(socket.assigns.editor_files, &(file_path_value(&1) == relative)) do
      socket
      |> assign(:active_file, relative)
      |> refresh_preview(workspace_root, true)
      |> sync.()
    else
      _ -> socket
    end
  end

  def open(socket, path, workspace_root, source, sync) do
    if available?(socket) do
      case resolve_file(path, workspace_root) do
        {:ok, relative} ->
          files = socket.assigns.editor_files
          active = socket.assigns.active_file
          exists? = Enum.any?(files, &(file_path_value(&1) == relative))

          if not exists? and length(files) >= 20 do
            if source == :user,
              do:
                Phoenix.LiveView.put_flash(
                  socket,
                  :error,
                  "You can open up to 20 files. Close a tab first."
                ),
              else: socket
          else
            files = if exists?, do: files, else: files ++ [%{path: relative, name: relative}]
            active = if source == :user or is_nil(active), do: relative, else: active

            if source == :user,
              do: Handbean.Search.touch(workspace_root, Path.expand(relative, workspace_root))

            socket
            |> assign(:editor_files, files)
            |> assign(:active_file, active)
            |> refresh_preview(workspace_root, active == relative)
            |> sync.()
          end

        {:error, reason} ->
          if source == :user do
            Phoenix.LiveView.put_flash(socket, :error, error_text(reason))
          else
            case relative_path(path, workspace_root) do
              {:ok, relative} when relative == socket.assigns.active_file ->
                refresh_preview(socket, workspace_root, true)

              _ ->
                socket
            end
          end
      end
    else
      socket
    end
  end

  def close(socket, path, workspace_root, sync) do
    with true <- available?(socket),
         {:ok, relative} <- relative_path(path, workspace_root),
         files = socket.assigns.editor_files,
         index when is_integer(index) <-
           Enum.find_index(files, &(file_path_value(&1) == relative)) do
      remaining = List.delete_at(files, index)

      active =
        if socket.assigns.active_file == relative,
          do: file_path_value(Enum.at(remaining, index) || List.last(remaining)),
          else: socket.assigns.active_file

      socket
      |> assign(:editor_files, remaining)
      |> assign(:active_file, active)
      |> refresh_preview(workspace_root)
      |> sync.()
    else
      _ -> socket
    end
  end

  def normalize(socket, conversation, root) do
    editor_files = Map.get(socket.assigns, :editor_files, [])
    active_file = Map.get(socket.assigns, :active_file)

    cond do
      not available?(socket) ->
        {[], nil}

      Map.get(socket.assigns, :editor_state_key) ==
          {state_key(conversation, root), editor_files, active_file} ->
        {editor_files, active_file}

      true ->
        normalize_stored(conversation, root)
    end
  end

  def state_key(conversation, root) do
    {conversation_value(conversation, "id", nil), root,
     conversation_value(conversation, "editor_files", []),
     conversation_value(conversation, "active_file", nil)}
  end

  def refresh_preview(socket, root, force? \\ false) do
    active = Map.get(socket.assigns, :active_file)
    key = {root, active}

    if force? or Map.get(socket.assigns, :file_preview_key) != key or
         (is_binary(active) and is_nil(Map.get(socket.assigns, :file_preview))) do
      preview = load_preview(active, root)

      socket
      |> assign(:file_preview_key, key)
      |> assign(:file_preview, preview)
      |> assign(:file_preview_error, preview_error(preview))
    else
      socket
    end
  end

  defp available?(socket) do
    Map.get(socket.assigns, :chat_scope) != :free and
      is_binary(Map.get(socket.assigns, :current_conversation_id))
  end

  defp normalize_stored(conversation, root) do
    files =
      (conversation_value(conversation, "editor_files", []) || [])
      |> Enum.flat_map(fn file ->
        case normalize_stored_path(file_path_value(file), root) do
          {:ok, relative} -> [%{path: relative, name: relative}]
          _ -> []
        end
      end)
      |> Enum.uniq_by(& &1.path)
      |> Enum.take(20)

    active =
      case normalize_stored_path(conversation_value(conversation, "active_file", nil), root) do
        {:ok, relative} -> relative
        _ -> nil
      end

    cond do
      is_nil(active) -> {files, nil}
      Enum.any?(files, &(&1.path == active)) -> {files, active}
      true -> {Enum.take(files, 19) ++ [%{path: active, name: active}], active}
    end
  end

  defp relative_path(path, root) when is_binary(path) and is_binary(root) do
    with true <- path != "" and not String.contains?(path, <<0>>),
         false <- ".." in Path.split(path),
         {:ok, canonical_root} <- PathValidator.canonicalize(root),
         {:ok, relative} <- relative_from_workspace(Path.expand(path, root), canonical_root),
         false <- ".." in Path.split(relative),
         :relative <- Path.type(relative),
         false <- relative == "." do
      {:ok, relative}
    else
      _ -> {:error, :invalid_path}
    end
  end

  defp relative_path(_, _), do: {:error, :invalid_path}

  defp relative_from_workspace(absolute, canonical_root),
    do: relative_from_workspace(Path.expand(absolute), canonical_root, [])

  defp relative_from_workspace(absolute, canonical_root, parts) do
    parent = Path.dirname(absolute)

    if parent == absolute do
      {:error, :outside_workspace}
    else
      parts = [Path.basename(absolute) | parts]

      case PathValidator.canonicalize(parent) do
        {:ok, ^canonical_root} ->
          case File.lstat(parent) do
            {:ok, %File.Stat{type: :directory}} -> {:ok, Path.join(parts)}
            _ -> {:error, :invalid_workspace_alias}
          end

        {:ok, _other} ->
          relative_from_workspace(parent, canonical_root, parts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_file(path, root) do
    with {:ok, relative} <- relative_path(path, root),
         :ok <- PathValidator.reject_resolved(Path.expand(relative, root)),
         {:ok, _absolute} <- Handbean.WorkspaceFiles.resolve(root, relative, :file) do
      {:ok, relative}
    end
  end

  defp normalize_stored_path(path, root) when is_binary(path) do
    if Path.type(path) == :relative do
      with {:ok, relative} <- relative_path(path, root),
           :ok <- PathValidator.reject_resolved(Path.expand(relative, root)) do
        case Handbean.WorkspaceFiles.resolve(root, relative, :file) do
          {:ok, _} -> {:ok, relative}
          {:error, :enoent} -> {:ok, relative}
          error -> error
        end
      end
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_stored_path(_path, _root), do: {:error, :invalid_path}

  defp load_preview(nil, _workspace_root), do: nil

  defp load_preview(path, workspace_root)
       when is_binary(path) and is_binary(workspace_root) do
    with {:ok, relative} <- resolve_file(path, workspace_root),
         {:ok, preview} <- Handbean.WorkspaceFiles.preview(workspace_root, relative) do
      preview
    else
      {:error, reason} -> {:error, error_text(reason)}
    end
  end

  defp load_preview(_, _), do: {:error, "Invalid file path"}

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(:enoent), do: "File no longer exists"
  defp error_text(:symlink), do: "Symbolic links cannot be previewed"
  defp error_text(:invalid_path), do: "Invalid file path"
  defp error_text(reason), do: "Unable to preview file: #{inspect(reason)}"

  defp preview_error({:error, reason}), do: error_text(reason)
  defp preview_error(_), do: nil

  defp file_path_value(nil), do: nil
  defp file_path_value(file) when is_map(file), do: conversation_value(file, "path", nil)
  defp file_path_value(_), do: nil

  defp conversation_value(conversation, key, default) do
    Handbean.Utils.SafeMap.get(conversation, key, default)
  end
end
