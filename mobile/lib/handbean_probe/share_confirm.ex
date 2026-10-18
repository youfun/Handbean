defmodule HandbeanProbe.ShareConfirm do
  @moduledoc """
  Confirm / cancel / workspace-copy outcomes for durable share intake.
  HomeScreen stays a projection of these results.
  """

  alias HandbeanProbe.{ShareCopy, ShareIntake, ShareWorkspaceImport}

  @spec begin(String.t(), map() | nil) ::
          {:ok, :structured, map()} | {:ok, :workspace_copy, map()} | {:error, term()}
  def begin(intake_id, workspace \\ nil) when is_binary(intake_id) do
    with {:ok, rec} <- ShareIntake.confirm(intake_id) do
      case rec["consumption"] do
        "workspace_copy" ->
          extras =
            case workspace do
              %{"path" => path} = ws ->
                %{"workspace_path" => path, "workspace_id" => ws["id"]}

              _ ->
                %{}
            end

          case ShareIntake.mark_confirming(intake_id, extras) do
            :ok -> {:ok, :workspace_copy, rec}
            other -> other
          end

        _ ->
          case ShareIntake.mark_merged(intake_id) do
            :ok -> {:ok, :structured, rec}
            other -> other
          end
      end
    end
  end

  def cancel(intake_id) when is_binary(intake_id) do
    ShareIntake.cancel(intake_id)
  end

  def schedule_cleanup(intake_id, opts \\ []) when is_binary(intake_id) do
    ShareIntake.schedule_cleanup(intake_id, opts)
  end

  def start_copy(intake_id, rec, workspace, owner, opts \\ []) do
    ShareCopy.begin(intake_id, rec, workspace, owner, opts)
  end

  def target_from(workspace, conversation_id, intake_id) do
    %{
      "intake_id" => intake_id,
      "workspace_id" => workspace && workspace["id"],
      "workspace_path" => workspace && workspace["path"],
      "conversation_id" => conversation_id
    }
  end

  def same_target?(current_workspace, current_conversation_id, target) when is_map(target) do
    workspace_ok =
      is_map(current_workspace) and
        current_workspace["id"] == target["workspace_id"] and
        current_workspace["path"] == target["workspace_path"]

    workspace_ok and current_conversation_id == target["conversation_id"]
  end

  def same_target?(_, _, _), do: false

  def apply_workspace(rec, workspace) do
    ShareWorkspaceImport.accept(rec, workspace)
  end

  def finish_workspace(intake_id, workspace, result) do
    case {result, ShareIntake.get(intake_id)} do
      {{:ok, paths}, {:ok, rec}} ->
        if rec["state"] == "cancelled" or ShareIntake.terminal?(intake_id) do
          {:rollback, workspace, intake_id, rec}
        else
          case ShareIntake.mark_merged(intake_id) do
            :ok ->
              {:merged, rec, paths}

            {:error, :terminal} ->
              {:rollback, workspace, intake_id, rec}

            {:error, reason} ->
              {:rollback, workspace, intake_id, {:error, reason}}
          end
        end

      {{:ok, _paths}, _} ->
        {:rollback, workspace, intake_id, %{}}

      {{:error, _reason}, {:ok, rec}} ->
        if rec["state"] == "cancelled" or ShareIntake.terminal?(intake_id) do
          {:rollback, workspace, intake_id, rec}
        else
          {:failed, rec, workspace, intake_id}
        end

      {{:error, reason}, _} ->
        {:failed, %{"reason" => reason}, workspace, intake_id}
    end
  end

  def schedule_rollback(workspace, intake_id, opts \\ []) do
    ShareCopy.request_rollback(intake_id, workspace, opts)
  end
end
