defmodule HandbeanProbe.HomeScreen.Share do
  @moduledoc """
  System share intake as seen by the screen: review list, confirm into the
  draft (current or new conversation), discard, workspace-copy outcomes and
  send acknowledgement.

  Manifest IO never runs in the screen process. `refresh/2` lists the durable
  FIFO under `HandbeanProbe.TaskSupervisor` and the result comes back as
  `{:share_intakes_ready, generation, {reviews, unknown?}}` (scope `:share_intakes_ready`
  in `HandbeanProbe.PendingRequests`, latest listing wins); `begin_send/2`
  marks intakes `send_pending` the same way under the `:composer` scope and
  replies `{:share_send_marked, generation, {inbound_id, result}}`. Confirmation
  (`ShareConfirm.begin/2`) stays synchronous: it is one guarded manifest write
  whose failure must be visible before the draft changes.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 2, assign: 3]
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.HomeScreen.{Async, Nav, Notice, Platform}
  alias HandbeanProbe.{ShareConfirm, ShareCopy, ShareIntake, ShareWorkspaceImport}

  @overflow ~w(too_many_pending overflow)

  # ── dispatch ──

  def handle({:share_intake_ready, _id, status}, socket) when status in @overflow do
    Notice.put_error(
      socket,
      gettext("Pending shares are full (max %{max}). Confirm or discard one first.",
        max: ShareIntake.max_pending()
      )
    )
  end

  def handle({:share_intake_ready, _id, "storage_error"}, socket) do
    Notice.put_error(
      socket,
      gettext("The share could not be written to local storage. Retry or free up space.")
    )
  end

  def handle({:share_intake_ready, id, _status}, socket) when is_binary(id),
    do: refresh(socket)

  def handle({:tap, {:share_confirm, id}}, socket), do: confirm(socket, id, :current)
  def handle({:tap, {:share_confirm_new, id}}, socket), do: confirm(socket, id, :new)
  def handle({:tap, {:share_discard, id}}, socket), do: discard(socket, id)

  def handle({:share_workspace_result, %{intake_id: _, target: _} = payload}, socket),
    do: finish_workspace(socket, payload)

  def handle({:share_rollback, id, _result}, socket) do
    socket
    |> assign(:share_confirming, Map.delete(socket.assigns.share_confirming, id))
    |> refresh()
  end

  def handle({:share_cleanup, _id, _result}, socket), do: socket

  # ── async refresh ──

  @doc """
  Re-list the review FIFO off-screen. `before:` runs first in the same task so
  writes that must precede the listing (return-to-review, boot reconcile)
  cannot race it.
  """
  def refresh(socket, opts \\ []) do
    before = Keyword.get(opts, :before, fn -> :ok end)

    Async.run(socket, :share_intakes_ready, fn ->
      before.()
      _ = ShareCopy.reconcile()
      reviews = ShareIntake.list_review()

      unknown? =
        Enum.any?(ShareIntake.list_send_pending(), fn rec ->
          ShareIntake.reconcile_send(rec) == :outcome_unknown
        end)

      {reviews, unknown?}
    end)
  end

  @doc "Latest `:share_intakes_ready` reply (staleness is settled by `Requests.take/3`)."
  def handle_ready(socket, {reviews, unknown?}) do
    merged = socket.assigns.merged_intake_ids
    reviews = Enum.reject(reviews, &MapSet.member?(merged, &1["intake_id"]))

    notice =
      if unknown? do
        Notice.info(
          gettext(
            "Send outcome unknown. Not resent automatically; check the conversation before deciding."
          ),
          :share
        )
      else
        Notice.clear_kind(socket.assigns.notice, :share)
      end

    assign(socket, share_intakes: reviews, notice: notice)
  end

  # ── send ──

  @doc """
  Mark merged intakes `send_pending` before the message leaves. Returns
  `{:ready, socket}` when nothing is merged, otherwise `{:pending, socket}`
  and the caller continues from `handle_send_marked/3`.
  """
  def begin_send(socket, inbound_id, deliver_as \\ :steer, composer_mode \\ :chat) do
    ids = MapSet.to_list(socket.assigns.merged_intake_ids)

    if ids == [] do
      {:ready, socket}
    else
      conversation_id = Nav.current_conversation_id(socket)

      # Bound to the composer scope: a reset / new conversation supersedes it.
      socket =
        Async.run(
          socket,
          :share_send_marked,
          fn -> {inbound_id, mark_send_pending(ids, inbound_id, conversation_id)} end,
          scope: :composer
        )

      {:pending,
       assign(socket, :share_send, %{
         inbound_id: inbound_id,
         deliver_as: deliver_as,
         composer_mode: composer_mode
       })}
    end
  end

  @doc "Returns `{:send, socket, inbound_id, deliver_as}` or `{:noop, socket}`."
  def handle_send_marked(socket, {inbound_id, result}) do
    case socket.assigns.share_send do
      %{inbound_id: ^inbound_id} = send_state ->
        socket = assign(socket, :share_send, nil)

        case result do
          :ok ->
            {:send, socket, inbound_id, Map.get(send_state, :deliver_as, :steer),
             Map.get(send_state, :composer_mode, :chat)}

          {:error, reason} ->
            {:noop,
             Notice.put_error(
               socket,
               gettext("The share send state could not be saved: %{reason}",
                 reason: inspect(reason)
               )
             )}
        end

      _ ->
        {:noop, socket}
    end
  end

  def after_send_ok(socket) do
    ids = MapSet.to_list(socket.assigns.merged_intake_ids)

    if ids != [],
      do: Async.fire(:share_acknowledged, fn -> Enum.each(ids, &ShareIntake.acknowledge/1) end)

    assign(socket, merged_intake_ids: MapSet.new(), share_send: nil)
  end

  def after_send_failed(socket) do
    ids = MapSet.to_list(socket.assigns.merged_intake_ids)

    if ids != [],
      do: Async.fire(:share_reverted, fn -> Enum.each(ids, &ShareIntake.revert_send/1) end)

    assign(socket, :share_send, nil)
  end

  # ── confirm / discard ──

  defp confirm(socket, intake_id, target) do
    a = socket.assigns

    if MapSet.member?(a.merged_intake_ids, intake_id) or
         Map.has_key?(a.share_confirming, intake_id) do
      refresh(socket)
    else
      case ShareConfirm.begin(intake_id, a.workspace) do
        {:ok, :structured, rec} ->
          socket |> blank_for(target) |> apply_structured(intake_id, rec)

        {:ok, :workspace_copy, rec} ->
          socket |> blank_for(target) |> start_workspace_copy(intake_id, rec)

        {:error, :not_reviewable} ->
          Notice.put_error(socket, Platform.platform_error(:not_reviewable))

        {:error, reason} ->
          Notice.put_error(socket, confirm_not_saved(reason))
      end
    end
  end

  defp blank_for(socket, :new), do: Nav.blank(socket)
  defp blank_for(socket, _), do: socket

  defp apply_structured(socket, intake_id, rec) do
    errors = List.wrap(rec["errors"])

    socket =
      Enum.reduce(List.wrap(rec["attachments"]), socket, fn att, acc ->
        Platform.add_attachment(acc, Map.put(att, "source", att["source"] || "share"))
      end)

    socket
    |> assign(
      draft: ShareIntake.append_share_text(socket.assigns.draft, ShareIntake.compose_text(rec)),
      merged_intake_ids: MapSet.put(socket.assigns.merged_intake_ids, intake_id),
      page: :chat
    )
    |> then(fn socket ->
      if errors == [],
        do: socket,
        else: Notice.put_error(socket, Platform.batch_error(errors))
    end)
    |> refresh()
  end

  defp start_workspace_copy(socket, intake_id, rec) do
    workspace = socket.assigns.workspace
    conversation_id = Nav.current_conversation_id(socket)
    target = ShareConfirm.target_from(workspace, conversation_id, intake_id)

    case ShareConfirm.start_copy(intake_id, rec, workspace, self(),
           conversation_id: conversation_id
         ) do
      {:ok, _} ->
        socket
        |> assign(
          share_confirming: Map.put(socket.assigns.share_confirming, intake_id, target),
          page: :chat
        )
        |> refresh()

      {:error, :busy} ->
        Notice.put_error(socket, gettext("The shared files could not be imported"))

      {:error, reason} ->
        Notice.put_error(socket, confirm_not_saved(reason))
    end
  end

  defp discard(socket, intake_id) do
    ctx = HandbeanProbe.NativeComposer.context(socket)

    case HandbeanProbe.Platform.Request.for_kind(:share_discard, ctx, self(), %{
           "intake_id" => intake_id
         }) do
      {:ok, req} -> _ = HandbeanProbe.Platform.start(req)
      {:error, _} -> :ok
    end

    confirming = socket.assigns.share_confirming
    target = confirming[intake_id]
    _ = ShareConfirm.cancel(intake_id)

    if is_map(target) and is_binary(target["workspace_path"]) do
      _ =
        ShareConfirm.schedule_rollback(
          %{"id" => target["workspace_id"], "path" => target["workspace_path"]},
          intake_id,
          notify: self()
        )
    end

    _ = ShareConfirm.schedule_cleanup(intake_id)

    socket
    |> assign(
      share_confirming: Map.delete(confirming, intake_id),
      merged_intake_ids: MapSet.delete(socket.assigns.merged_intake_ids, intake_id)
    )
    |> refresh()
  end

  # `payload` is the in-BEAM `ShareCopy` notification (atom keys); `target`
  # is the string-keyed manifest target.
  defp finish_workspace(socket, %{intake_id: id, result: result, target: target}) do
    confirming = socket.assigns.share_confirming
    stored = confirming[id] || target || %{}
    current_workspace = socket.assigns.workspace
    current_conv = Nav.current_conversation_id(socket)
    target_workspace = %{"id" => stored["workspace_id"], "path" => stored["workspace_path"]}
    failed = gettext("The shared files could not be imported")

    cond do
      not is_map(stored) or not is_binary(stored["workspace_path"]) ->
        socket

      not Map.has_key?(confirming, id) ->
        _ = ShareConfirm.schedule_rollback(target_workspace, id, notify: self())
        socket

      not ShareConfirm.same_target?(current_workspace, current_conv, stored) ->
        _ = ShareConfirm.schedule_rollback(target_workspace, id, notify: self())

        socket
        |> assign(:share_confirming, Map.delete(confirming, id))
        |> Notice.put_error(failed)
        |> refresh()

      true ->
        case ShareConfirm.finish_workspace(id, target_workspace, result) do
          {:merged, rec, paths} ->
            errors = List.wrap(rec["errors"])
            _ = ShareCopy.ack(id)

            socket
            |> assign(
              draft: ShareWorkspaceImport.merge_draft(socket.assigns.draft, rec, paths),
              merged_intake_ids: MapSet.put(socket.assigns.merged_intake_ids, id),
              share_confirming: Map.delete(confirming, id)
            )
            |> Notice.put_error(if(errors == [], do: nil, else: Platform.batch_error(errors)))
            |> refresh()

          {:rollback, workspace, intake_id, _} ->
            _ = ShareConfirm.schedule_rollback(workspace, intake_id, notify: self())
            socket |> assign(:share_confirming, Map.delete(confirming, id)) |> refresh()

          {:failed, _rec, workspace, intake_id} ->
            _ = ShareConfirm.schedule_rollback(workspace, intake_id, notify: self())

            socket
            |> assign(:share_confirming, Map.delete(confirming, id))
            |> Notice.put_error(failed)
            |> refresh()
        end
    end
  end

  defp mark_send_pending(ids, inbound_id, conversation_id) do
    {ok_ids, error} =
      Enum.reduce_while(ids, {[], :ok}, fn intake_id, {done, :ok} ->
        case ShareIntake.mark_send_pending(intake_id, inbound_id, conversation_id) do
          :ok -> {:cont, {[intake_id | done], :ok}}
          {:error, reason} -> {:halt, {done, {:error, reason}}}
        end
      end)

    case error do
      :ok ->
        :ok

      {:error, reason} ->
        Enum.each(ok_ids, &ShareIntake.revert_send/1)
        {:error, reason}
    end
  end

  defp confirm_not_saved(reason),
    do: gettext("The share confirmation could not be saved: %{reason}", reason: inspect(reason))

  # ── render ──

  def render_review([], _assigns), do: nil

  def render_review(intakes, assigns) do
    node(
      :column,
      [fill_width: true, padding_bottom: 8],
      [
        text(gettext("From share"), text_size: 13, font_weight: "bold"),
        text(target_label(assigns), text_size: 12, font_weight: "bold"),
        text(
          gettext(
            "Confirming only adds to the current draft and does not send. Selected text and photos are sent to the model service in Settings only after you send."
          ),
          text_size: 11
        )
      ] ++ Enum.map(intakes, &review_card/1)
    )
  end

  defp target_label(assigns) do
    workspace =
      case assigns do
        %{workspace: %{"name" => name}} when is_binary(name) and name != "" -> name
        _ -> gettext("Workspace")
      end

    title =
      case assigns do
        %{chat: %{conversation: %{"title" => title}}} when is_binary(title) and title != "" ->
          title

        _ ->
          gettext("New conversation")
      end

    gettext("Current target: %{workspace} · %{conversation}",
      workspace: workspace,
      conversation: title
    )
  end

  defp review_card(rec) do
    id = rec["intake_id"]
    errors = List.wrap(rec["errors"])
    files = List.wrap(rec["files"])
    excerpt = ShareIntake.compose_text(rec)
    excerpt = if excerpt == "", do: gettext("Shared material"), else: excerpt
    partial = if errors == [], do: "", else: " · " <> gettext("partly failed")

    kind_label =
      if (rec["consumption"] || "structured_attachments") == "workspace_copy" do
        ready = Enum.count(files, &(&1["status"] == "ready"))
        gettext("Will copy into the workspace · %{count} files", count: ready) <> partial
      else
        gettext("Attachments %{count}", count: length(List.wrap(rec["attachments"]))) <> partial
      end

    node(:column, [fill_width: true, padding_top: 8], [
      text(gettext("System share"), text_size: 11, text_color: color(:muted)),
      text(String.slice(to_string(excerpt), 0, 80), text_size: 12),
      text(kind_label, text_size: 11),
      if(rec["text_truncated"] == true,
        do:
          text(gettext("The shared text was shortened because it was too long."),
            text_size: 11,
            text_color: color(:danger)
          )
      ),
      Enum.map(files, fn item ->
        text(ShareWorkspaceImport.item_label(item),
          text_size: 11,
          text_color: if(item["status"] == "ready", do: color(:ink), else: color(:danger))
        )
      end),
      actions_row([
        button(gettext("Add to current draft"), {:share_confirm, id}, text_size: 11, padding: 6),
        button(gettext("New conversation draft"), {:share_confirm_new, id},
          text_size: 11,
          padding: 6
        ),
        button(gettext("Discard"), {:share_discard, id}, text_size: 11, padding: 6)
      ])
    ])
  end
end
