defmodule Handbean.Permissions.ConversationMode do
  @moduledoc """
  Durable conversation-owned permission mode and its run-time projection.

  Workspace tool rules remain constraints. This module owns only the broad
  conversation choice shown by chat surfaces.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationPermissionChange, ConversationRun}

  @topic "conversation:permission_mode"
  @modes [:prompt, :auto_review, :yolo]
  @default :auto_review
  @open_run_statuses ["running", "interrupted"]

  @type mode :: :prompt | :auto_review | :yolo

  def default, do: @default
  def modes, do: @modes

  def subscribe do
    Phoenix.PubSub.subscribe(Handbean.PubSub, @topic)
  end

  def get(conversation) when is_map(conversation) do
    conversation
    |> Handbean.Utils.SafeMap.get_any(:permission_mode, "permission_mode")
    |> normalize()
    |> case do
      {:ok, mode} -> mode
      {:error, _reason} -> scope_default(conversation)
    end
  end

  def get(conversation_id) when is_binary(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{} = conversation -> get(conversation)
      nil -> @default
    end
  end

  def get(_conversation), do: @default

  def resolve(mode, delegated_approval \\ nil) do
    mode = if delegated_approval in [:yolo, "yolo"], do: :yolo, else: mode

    mode =
      if delegated_approval in [:auto_review, "auto_review"], do: :auto_review, else: mode

    case normalize(mode) do
      {:ok, :prompt} ->
        %{permission_mode: :prompt, approval_mode: :prompt, reviewer: :user}

      {:ok, :auto_review} ->
        %{permission_mode: :auto_review, approval_mode: :auto, reviewer: :auto_review}

      {:ok, :yolo} ->
        %{permission_mode: :yolo, approval_mode: :yolo, reviewer: :user}

      {:error, _reason} ->
        resolve(@default, delegated_approval)
    end
  end

  def runtime(conversation_id, delegated_approval \\ nil) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{status: "active"} = conversation ->
        conversation
        |> get()
        |> resolve(delegated_approval)
        |> Map.put(:permission_revision, conversation.permission_revision || 0)

      _missing ->
        @default
        |> resolve(delegated_approval)
        |> Map.put(:permission_revision, 0)
    end
  end

  def update(conversation_id, mode, opts \\ [])

  def update(conversation_id, mode, opts) when is_binary(conversation_id) do
    with {:ok, mode} <- normalize(mode) do
      source = opts |> Keyword.get(:source, :user) |> to_string()
      requested_run_id = Keyword.get(opts, :run_id)

      result =
        Repo.transaction(
          fn ->
            case Repo.get(Conversation, conversation_id) do
              %Conversation{status: "active", scope: "workspace"} = conversation ->
                persist_change(conversation, mode, requested_run_id, source)

              _missing_or_read_only ->
                Repo.rollback(:not_found)
            end
          end,
          mode: :immediate
        )

      case result do
        {:ok, %{metadata: metadata, changed?: true, revision: revision, run_id: run_id}} ->
          Phoenix.PubSub.broadcast(
            Handbean.PubSub,
            @topic,
            {:conversation_permission_mode_changed, conversation_id, mode, run_id, revision}
          )

          {:ok, metadata}

        {:ok, %{metadata: metadata}} ->
          {:ok, metadata}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def update(_conversation_id, _mode, _opts), do: {:error, :invalid_mode}

  @doc false
  def observe_run(conversation_id, run_id, delegated_approval \\ nil)

  def observe_run(conversation_id, run_id, _delegated_approval)
      when is_binary(conversation_id) and is_binary(run_id) do
    Repo.transaction(
      fn ->
        with %Conversation{status: "active"} = conversation <-
               Repo.get(Conversation, conversation_id),
             %ConversationRun{status: status} = run when status in @open_run_statuses <-
               Repo.get_by(ConversationRun, conversation_id: conversation_id, run_id: run_id) do
          project_run_observation(conversation, run)
        end

        :ok
      end,
      mode: :immediate
    )
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def observe_run(_conversation_id, _run_id, _delegated_approval), do: :ok

  @doc false
  def settle_run_end(_conversation_id, _run_id, true), do: :ok

  def settle_run_end(conversation_id, run_id, _orphan_recovery?)
      when is_binary(conversation_id) and is_binary(run_id) do
    with %Conversation{status: "active"} = conversation <- Repo.get(Conversation, conversation_id),
         %ConversationRun{status: status} = run when status in @open_run_statuses <-
           Repo.get_by(ConversationRun, conversation_id: conversation_id, run_id: run_id) do
      project_run_observation(conversation, run)
    end

    :ok
  end

  def settle_run_end(_conversation_id, _run_id, _orphan_recovery?), do: :ok

  def normalize(mode) when mode in @modes, do: {:ok, mode}

  def normalize(mode) when is_binary(mode) do
    case mode do
      "prompt" -> {:ok, :prompt}
      "auto_review" -> {:ok, :auto_review}
      "yolo" -> {:ok, :yolo}
      _ -> {:error, :invalid_mode}
    end
  end

  def normalize(_mode), do: {:error, :invalid_mode}

  defp persist_change(conversation, mode, requested_run_id, source) do
    from_mode = get(conversation)

    if from_mode == mode do
      %{
        metadata: Handbean.ConversationStore.Codec.base_metadata(conversation),
        changed?: false,
        revision: conversation.permission_revision || 0,
        run_id: nil
      }
    else
      timestamp = DateTime.utc_now()
      revision = (conversation.permission_revision || 0) + 1
      run_id = open_run_id(conversation.id, requested_run_id)

      updated =
        conversation
        |> Changeset.change(
          permission_mode: to_string(mode),
          permission_revision: revision,
          updated_at: timestamp
        )
        |> Repo.update!()

      %ConversationPermissionChange{}
      |> Changeset.change(%{
        conversation_id: conversation.id,
        run_id: run_id,
        from_mode: to_string(from_mode),
        to_mode: to_string(mode),
        source: source,
        revision: revision,
        changed_at: timestamp
      })
      |> Repo.insert!()

      if run_id do
        run = Repo.get_by!(ConversationRun, conversation_id: conversation.id, run_id: run_id)
        resolved = resolve(mode, run.delegated_approval)

        Repo.update_all(
          from(item in ConversationRun,
            where:
              item.conversation_id == ^conversation.id and item.run_id == ^run_id and
                item.status in ^@open_run_statuses
          ),
          set: [
            current_permission_mode: to_string(resolved.permission_mode),
            current_permission_revision: revision,
            permission_changed_at: timestamp
          ]
        )
      end

      %{
        metadata: Handbean.ConversationStore.Codec.base_metadata(updated),
        changed?: true,
        revision: revision,
        run_id: run_id
      }
    end
  end

  defp open_run_id(_conversation_id, run_id) when not is_binary(run_id) or run_id == "", do: nil

  defp open_run_id(conversation_id, run_id) do
    case Repo.get_by(ConversationRun, conversation_id: conversation_id, run_id: run_id) do
      %ConversationRun{status: status} when status in @open_run_statuses -> run_id
      _closed_or_missing -> nil
    end
  end

  defp project_run_observation(conversation, run) do
    resolved = resolve(get(conversation), run.delegated_approval)
    revision = conversation.permission_revision || 0
    initial_revision = run.initial_permission_revision || revision
    changed_at = latest_change_at(conversation.id, initial_revision, revision)

    Repo.update_all(
      from(item in ConversationRun,
        where:
          item.conversation_id == ^conversation.id and item.run_id == ^run.run_id and
            item.status in ^@open_run_statuses
      ),
      set: [
        current_permission_mode: to_string(resolved.permission_mode),
        current_permission_revision: revision,
        permission_changed_at: changed_at
      ]
    )

    Repo.update_all(
      from(change in ConversationPermissionChange,
        where:
          change.conversation_id == ^conversation.id and is_nil(change.run_id) and
            change.revision > ^initial_revision and change.revision <= ^revision
      ),
      set: [run_id: run.run_id]
    )

    :ok
  end

  defp latest_change_at(_conversation_id, initial_revision, revision)
       when revision <= initial_revision,
       do: nil

  defp latest_change_at(conversation_id, initial_revision, revision) do
    Repo.one(
      from change in ConversationPermissionChange,
        where:
          change.conversation_id == ^conversation_id and change.revision > ^initial_revision and
            change.revision <= ^revision,
        order_by: [desc: change.revision, desc: change.id],
        limit: 1,
        select: change.changed_at
    )
  end

  defp scope_default(conversation) do
    case Handbean.Utils.SafeMap.get_any(conversation, :scope, "scope") do
      scope when scope in [:free, "free"] -> :prompt
      _ -> @default
    end
  end
end
