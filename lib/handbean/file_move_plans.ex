defmodule Handbean.FileMovePlans do
  @moduledoc """
  Durable, conversation-bound file move plans and host-confirmed selections.

  Tools can propose and execute, but cannot confirm a selection. The trusted host
  calls `confirm/4`; execute consumes only the immutable stored selection. A CAS
  claim prevents concurrent/repeated execution. An interrupted `executing`
  claim is frozen as `needs_review` and never replayed: rows marked moving require inspection of both paths.

  Only regular files within the current checkout are supported. An exclusive
  hard link followed by unlink provides a same-filesystem no-replace move;
  unsupported filesystems fail without falling back to an overwriting rename.
  Path checks are not atomic against a concurrent hostile directory replacement.
  """

  import Ecto.Query

  alias Handbean.FileMovePlans.{Files, Plan}
  alias Handbean.{ConversationStore, Repo, WorkspaceFiles}

  @max_entries 20
  @max_total_bytes 128 * 1024 * 1024

  def create(context, attrs) when is_map(context) and is_map(attrs) do
    with {:ok, identity} <- identity(context),
         {:ok, title} <- title(attrs),
         {:ok, entries} <- prepare_entries(identity.checkout_path, field(attrs, "entries")),
         {:ok, plan} <- insert(identity, title, entries) do
      notify(plan)
      {:ok, plan}
    end
  end

  def create(_, _), do: {:error, :invalid_plan}

  def get(context, id) when is_map(context) and is_binary(id) do
    with {:ok, identity} <- identity(context),
         %Plan{} = plan <- Repo.get(Plan, id),
         true <- bound?(plan, identity) do
      {:ok, plan}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  def get(_, _), do: {:error, :not_found}

  @doc "Persist a host UI selection. This operation is intentionally not a model tool."
  def confirm(context, id, version, ids) do
    with {:ok, plan} <- get(context, id),
         :ok <- active(plan),
         :ok <- selection(plan, ids) do
      cond do
        plan.status == "confirmed" and Enum.sort(ids) == Enum.sort(plan.selected_ids) ->
          {:ok, plan}

        plan.status != "draft" or plan.version != version ->
          {:error, :stale_plan}

        true ->
          write(plan, status: "confirmed", selected_ids: Enum.sort(ids))
      end
    end
  end

  @doc "Execute only the selection stored by the host, after normal tool authorization."
  def execute(context, id) do
    with {:ok, plan} <- get(context, id) do
      case plan.status do
        "confirmed" -> execute_confirmed(plan)
        "draft" -> {:error, :host_confirmation_required}
        "executing" -> freeze_interrupted(plan)
        _ -> {:ok, plan}
      end
    end
  end

  defp execute_confirmed(plan) do
    with :ok <- active(plan),
         {:ok, claimed} <- write(plan, status: "executing") do
      case preflight(claimed) do
        :ok -> move_entries(claimed)
        {:error, id, reason} -> fail_entry(claimed, id, reason)
      end
    end
  end

  # Crash after claim is not a successful result and must not continue the batch.
  defp freeze_interrupted(plan) do
    write(plan, status: "needs_review")
  end

  defp preflight(plan) do
    Enum.reduce_while(selected(plan), :ok, fn entry, :ok ->
      case Files.prepare_destination(plan.checkout_path, entry) do
        {:ok, _source, _target} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, entry["id"], reason}}
      end
    end)
  end

  defp move_entries(plan) do
    result =
      Enum.reduce_while(selected(plan), {:ok, plan}, fn entry, {:ok, current} ->
        with {:ok, moving} <- write_entry(current, entry["id"], "moving"),
             :ok <- Files.move(moving.checkout_path, entry),
             {:ok, completed} <- write_entry(moving, entry["id"], "completed") do
          {:cont, {:ok, completed}}
        else
          {:error, reason} -> {:halt, fail_current(plan.id, entry["id"], reason)}
        end
      end)

    case result do
      {:ok, %{status: "executing"} = current} -> write(current, status: "completed")
      other -> other
    end
  end

  defp fail_current(plan_id, entry_id, reason) do
    # Re-read after each durable transition; never erase earlier per-item receipts.
    case Repo.get(Plan, plan_id) do
      %Plan{} = current -> fail_entry(current, entry_id, reason)
      _ -> {:error, :not_found}
    end
  end

  defp fail_entry(plan, entry_id, reason) do
    with {:ok, updated} <- write_entry(plan, entry_id, "failed", inspect(reason)) do
      write(updated, status: "failed")
    end
  end

  defp selected(plan), do: Enum.filter(plan.entries, &(&1["id"] in plan.selected_ids))

  defp write_entry(plan, id, status, error \\ nil) do
    entries =
      Enum.map(plan.entries, fn entry ->
        if entry["id"] == id,
          do: Map.merge(entry, %{"status" => status, "error" => error}),
          else: entry
      end)

    write(plan, entries: entries)
  end

  defp write(plan, fields) do
    changes = [version: plan.version + 1, updated_at: now()] ++ fields

    result =
      from(p in Plan, where: p.id == ^plan.id and p.version == ^plan.version)
      |> Repo.update_all(set: changes)

    case result do
      {1, _} ->
        updated = struct(plan, changes)
        notify(updated)
        {:ok, updated}

      _ ->
        {:error, :stale_plan}
    end
  end

  defp insert(identity, title, entries) do
    clock = now()

    attrs =
      Map.merge(identity, %{
        id: Ecto.UUID.generate(),
        title: title,
        entries: entries,
        selected_ids: [],
        expires_at: DateTime.add(clock, 86_400, :second),
        inserted_at: clock,
        updated_at: clock
      })

    %Plan{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.validate_required([
      :id,
      :conversation_id,
      :workspace_id,
      :checkout_path,
      :title,
      :entries,
      :expires_at
    ])
    |> Ecto.Changeset.foreign_key_constraint(:conversation_id)
    |> Repo.insert()
  end

  defp identity(context) do
    with conversation_id when is_binary(conversation_id) <- context[:conversation_id],
         workspace_id when is_binary(workspace_id) <- context[:workspace_id],
         root when is_binary(root) <- context[:working_directory],
         {:ok, conversation} <- ConversationStore.get(conversation_id),
         true <- conversation["workspace_id"] == workspace_id,
         {:ok, checkout} <- ConversationStore.effective_checkout_path(conversation),
         {:ok, canonical} <- Handbean.RepoIdentity.canonical_directory(root),
         true <- canonical == checkout,
         {:ok, normalized} <- WorkspaceFiles.resolve(canonical, "", :directory) do
      {:ok,
       %{conversation_id: conversation_id, workspace_id: workspace_id, checkout_path: normalized}}
    else
      _ -> {:error, :workspace_conversation_required}
    end
  end

  defp bound?(plan, identity) do
    plan.conversation_id == identity.conversation_id and
      plan.workspace_id == identity.workspace_id and plan.checkout_path == identity.checkout_path
  end

  defp active(plan) do
    if DateTime.compare(now(), plan.expires_at) == :lt,
      do: :ok,
      else: {:error, :expired_plan}
  end

  defp title(attrs) do
    case field(attrs, "title") || "文件整理" do
      title when is_binary(title) and byte_size(title) in 1..200 -> {:ok, title}
      _ -> {:error, :invalid_title}
    end
  end

  defp selection(plan, ids) when is_list(ids) and ids != [] do
    available = MapSet.new(plan.entries, & &1["id"])

    if length(ids) == MapSet.size(MapSet.new(ids)) and
         Enum.all?(ids, &MapSet.member?(available, &1)),
       do: :ok,
       else: {:error, :invalid_selection}
  end

  defp selection(_, _), do: {:error, :invalid_selection}

  defp prepare_entries(root, entries)
       when is_list(entries) and length(entries) in 1..@max_entries do
    result =
      Enum.reduce_while(entries, {:ok, []}, fn input, {:ok, acc} ->
        case Files.prepare(root, input) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, reversed} <- result do
      entries = Enum.reverse(reversed)
      sources = Enum.map(entries, &Files.path_key(&1["source"]))
      targets = Enum.map(entries, &Files.path_key(&1["target"]))

      cond do
        length(Enum.uniq(sources)) != length(sources) or
            length(Enum.uniq(targets)) != length(targets) ->
          {:error, :duplicate_path}

        not MapSet.disjoint?(MapSet.new(sources), MapSet.new(targets)) ->
          {:error, :overlapping_paths}

        Enum.sum(Enum.map(entries, & &1["size"])) > @max_total_bytes ->
          {:error, :plan_too_large}

        true ->
          {:ok, entries}
      end
    end
  end

  defp prepare_entries(_, _), do: {:error, :invalid_entries}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp notify(plan) do
    Phoenix.PubSub.broadcast(
      Handbean.PubSub,
      "runtime:file_move_plans",
      {:file_move_plan_changed, plan.conversation_id}
    )
  end
end
