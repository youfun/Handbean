defmodule HandbeanProbe.NativeWorkspaceImport do
  @moduledoc """
  SAF import requests: request ids, receipt validation, registration, and
  rollback. The tree copy itself is owned by Android (`WorkspaceImport.kt`);
  Elixir only accepts the committed `imported_workspaces/<request_id>` path.
  """

  alias Handbean.WorkspaceStore
  alias HandbeanProbe.Bridge.Inbound
  alias HandbeanProbe.NativeWorkspaces

  def idle, do: %{request_id: nil, status: :idle}

  def start(current) do
    current = current || idle()

    if current.status in [:picking, :copying] do
      {:error, :busy}
    else
      request_id = "imp_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      case start_picker(request_id) do
        :ok ->
          {:ok, %{request_id: request_id, status: :picking}}

        {:error, :unavailable} ->
          if test_env?() do
            {:ok, %{request_id: request_id, status: :picking}}
          else
            {:error, :unavailable}
          end
      end
    end
  end

  def cancel(state) do
    state = state || idle()

    if state.request_id do
      send_picker([%{"kind" => "cancel_directory", "request_id" => state.request_id}])
      %{state | status: :cancelled}
    else
      idle()
    end
  end

  def handle_cancelled(state) do
    state = state || idle()

    cond do
      state.status == :cancelled ->
        {:ignored, idle()}

      state.status in [:picking, :copying] ->
        {:cancelled, idle()}

      true ->
        {:ignored, state}
    end
  end

  def handle_picked(state, items) do
    state = state || idle()

    %Inbound.PickedFile{request_id: request_id, path: path, error: error, name: name} =
      items |> List.wrap() |> List.first() |> Inbound.picked_file()

    name = name || (is_binary(path) && Path.basename(path))

    cond do
      not match_request?(state.request_id, request_id) ->
        cleanup_receipt(path, request_id)
        {:ignored, state}

      state.status == :cancelled ->
        cleanup_receipt(path, request_id)
        {:ignored, idle()}

      state.status not in [:picking, :copying] ->
        cleanup_receipt(path, request_id)
        {:ignored, state}

      is_binary(error) ->
        reason =
          case error do
            "cancelled" -> :cancelled
            "too_large" -> :too_large
            "unsafe_name" -> :unsafe_name
            _ -> :copy_failed
          end

        {:error, reason, idle()}

      not is_binary(path) or path == "" ->
        {:error, :copy_failed, idle()}

      true ->
        register_import(state, path, name)
    end
  end

  def start_picker(request_id) do
    send_picker([%{"kind" => "directory", "request_id" => request_id}])
  end

  defp send_picker(envelope) do
    try do
      :mob_nif.files_pick(IO.iodata_to_binary(:json.encode(envelope)))
      :ok
    rescue
      UndefinedFunctionError -> {:error, :unavailable}
      ErlangError -> {:error, :unavailable}
    catch
      :error, :undef -> {:error, :unavailable}
    end
  end

  defp register_import(state, path, name) do
    with {:ok, dest} <- materialize(path, state.request_id),
         :ok <- validate_dest(dest),
         {:ok, workspace} <- WorkspaceStore.add(dest, name: name || Path.basename(dest)) do
      {:ok, workspace, idle()}
    else
      {:error, reason} ->
        cleanup_receipt(path, state.request_id)
        {:error, reason, idle()}
    end
  end

  defp materialize(path, request_id) do
    if path == Path.join(NativeWorkspaces.imported_root(), request_id) and
         NativeWorkspaces.owned_path?(path, NativeWorkspaces.imported_root()) do
      {:ok, path}
    else
      {:error, :copy_failed}
    end
  end

  defp validate_dest(path) do
    cond do
      not File.dir?(path) ->
        {:error, :copy_failed}

      match?({:error, _}, File.ls(path)) ->
        {:error, :copy_failed}

      true ->
        :ok
    end
  end

  defp test_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp match_request?(expected, actual) when is_binary(expected) and is_binary(actual),
    do: expected == actual

  defp match_request?(_, _), do: false

  defp cleanup_receipt(path, request_id) do
    if is_binary(path) and is_binary(request_id) and
         path == Path.join(NativeWorkspaces.imported_root(), request_id) and
         NativeWorkspaces.owned_path?(path, NativeWorkspaces.imported_root()) do
      case WorkspaceStore.get_by_path(path) do
        {:ok, _} -> :ok
        _ -> File.rm_rf(path)
      end
    else
      :ok
    end
  end
end
