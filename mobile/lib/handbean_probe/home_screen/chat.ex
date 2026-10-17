defmodule HandbeanProbe.HomeScreen.Chat do
  @moduledoc """
  The conversation itself: draft edits, send / stop / new chat, timeline
  toggles, tool actions, approval decisions and permission mode, and the
  `Handbean.PubSub.Session` events projected by `HandbeanProbe.NativeChat`.

  Sending with merged share intakes is two-phase: `Share.begin_send/2` marks
  them off-screen and the send continues from `send_after_intake_pending/2`
  when `{:share_send_marked, …}` arrives.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 2, assign: 3]

  alias Handbean.Agent.Delegation
  alias HandbeanProbe.HomeScreen.{Nav, Notice, Platform, Share}

  alias HandbeanProbe.{
    NativeApproval,
    NativeChat,
    NativeArtifactDelivery,
    NativeTimeline,
    NativeWorkspaces
  }

  @toggles [:toggle_tool_work, :toggle_work_segment, :toggle_tool_output, :toggle_file_diff]

  # ── dispatch ──

  def handle({:change, :draft, text}, socket), do: assign(socket, :draft, text)
  def handle({:change, :review_place, text}, socket), do: assign(socket, :review_place, text)
  def handle({:change, :review_feeling, text}, socket), do: assign(socket, :review_feeling, text)
  def handle({:submit, :send}, socket), do: handle({:tap, :send}, socket)

  def handle({:tap, :toggle_composer_mode}, socket) do
    next = if socket.assigns.composer_mode == :review, do: :chat, else: :review
    assign(socket, :composer_mode, next)
  end

  def handle({:tap, :generate_review}, socket) do
    start_send(socket, :review)
  end

  def handle({:tap, :toggle_deliver_mode}, socket) do
    next = if socket.assigns.deliver_mode == :follow_up, do: :steer, else: :follow_up
    assign(socket, :deliver_mode, next)
  end

  def handle({:tap, {:cancel_pending, id}}, socket), do: cancel_pending(socket, id)
  def handle({:tap, {:resend_pending, id}}, socket), do: resend_pending(socket, id)

  def handle({:tap, :send}, socket), do: start_send(socket, :chat)

  def handle({:top_reached, :load_older_history}, %{assigns: %{chat: chat}} = socket)
      when not is_nil(chat) do
    assign(socket, :chat, NativeChat.load_older(chat))
  end

  def handle({:top_reached, :load_older_history}, socket), do: socket

  def handle({:tap, :stop}, %{assigns: %{chat: chat}} = socket) when not is_nil(chat) do
    case Handbean.Agent.Coordinator.cancel(chat.conversation["id"]) do
      :ok -> socket |> assign(:stopping, true) |> Notice.clear()
      {:error, _} -> assign(socket, :chat, NativeChat.load(chat.conversation))
    end
  end

  def handle({:tap, :stop}, socket), do: socket

  def handle({:tap, :new_chat}, socket) do
    socket = socket |> Nav.reset_composer() |> Nav.blank()
    a = socket.assigns

    assign(socket,
      draft: NativeWorkspaces.get_draft(a.drafts, a.workspace, nil),
      free_draft: false
    )
  end

  def handle({:tap, :new_free_chat}, socket) do
    socket = socket |> Nav.reset_composer() |> Nav.blank()
    a = socket.assigns

    socket
    |> assign(
      draft: NativeWorkspaces.get_draft(a.drafts, nil, nil),
      free_draft: true,
      page: :chat,
      workspace_tree: HandbeanProbe.NativeWorkspaceTree.idle()
    )
  end

  def handle({:tap, {:copy_relative_path, path}}, socket) when is_binary(path) do
    HandbeanProbe.ModelSettings.Subscriptions.copy(socket, path)
  end

  def handle({:tap, {action, id}}, socket) when action in @toggles do
    a = socket.assigns
    entries = NativeTimeline.project(a.chat, a.work_groups, a.work_segments, a.tool_outputs)

    {key, value} =
      case action do
        :toggle_tool_work ->
          entry = Enum.find(entries, &(&1["work_group_id"] == id))
          {:work_groups, entry && entry["work_collapsed"] == true}

        :toggle_work_segment ->
          entry = Enum.find(entries, &(&1["work_segment_id"] == id))
          {:work_segments, entry && entry["work_segment_open"] != true}

        :toggle_tool_output ->
          {:tool_outputs, not Map.get(a.tool_outputs, id, false)}

        :toggle_file_diff ->
          {:file_diffs, not Map.get(a.file_diffs, id, false)}
      end

    assign(socket, key, Map.put(Map.fetch!(a, key), id, value))
  end

  def handle({:tap, {:tool_action, conversation_id, kind, id}}, socket)
      when kind in [:preview, :browser] do
    if current?(socket, conversation_id) do
      owner = self()

      Task.Supervisor.start_child(HandbeanProbe.TaskSupervisor, fn ->
        result = NativeChat.open_tool_action(conversation_id, kind, id)
        send(owner, {:tool_action_result, conversation_id, result})
      end)
    end

    socket
  end

  def handle({:tool_action_result, id, result}, socket) do
    cond do
      not current?(socket, id) ->
        socket

      result == :ok ->
        Notice.clear(socket)

      true ->
        Notice.put_error(
          socket,
          gettext("Could not open. Check that the session is still available.")
        )
    end
  end

  def handle({:tap, :dismiss_approval}, socket), do: assign(socket, :approval_open, false)
  def handle({:tap, :review_approval}, socket), do: assign(socket, :approval_open, true)

  def handle({:tap, {:composer_select, which}}, socket)
      when which in [:model, :reasoning, :permission] do
    next = if socket.assigns.composer_select == which, do: nil, else: which
    assign(socket, :composer_select, next)
  end

  def handle({:tap, {:permission_mode, mode}}, socket)
      when mode in [:prompt, :auto_review, :yolo] do
    case Handbean.WorkspaceSettings.update_permission_mode(socket.assigns.workspace["path"], mode) do
      :ok ->
        socket
        |> assign(permission_mode: mode, page: :chat, composer_select: nil)
        |> Notice.clear()

      {:error, _} ->
        Notice.put_error(
          socket,
          gettext("Permission settings could not be saved. Please try again.")
        )
    end
  end

  def handle({:tap, {:approval, id, seq, action, scope}}, socket) do
    chat = socket.assigns.chat

    if chat && chat.conversation["id"] == id && chat.approval_seq == seq && chat.pending_approval do
      decide(socket, chat, action, scope)
    else
      socket
    end
  end

  def handle({:agent_event, event}, %{assigns: %{chat: chat}} = socket) when not is_nil(chat) do
    projected = NativeChat.project(event, chat) |> schedule_reload()
    socket = assign(socket, :chat, projected)

    socket =
      cond do
        projected.approval_seq != chat.approval_seq && projected.pending_approval ->
          socket
          |> NativeArtifactDelivery.supersede_approval_batch()
          |> assign(approval_open: true, approval_snapshots: %{})
          |> NativeArtifactDelivery.reconcile_approval_exports(projected)

        chat.pending_approval && is_nil(projected.pending_approval) ->
          NativeArtifactDelivery.supersede_approval_batch(socket)

        true ->
          socket
      end

    settle_stopping(socket, projected)
  end

  def handle({:agent_event, _event}, socket), do: socket

  def handle({:reload_transcript, id}, socket) do
    if current?(socket, id) do
      projected = NativeChat.apply_deferred_reload(socket.assigns.chat)
      socket |> assign(:chat, projected) |> settle_stopping(projected)
    else
      socket
    end
  end

  def handle({:alert, :cancel_all_runs}, socket) do
    Handbean.Runtime.cancel_all_runs()
    socket
  end

  # ── send ──

  defp start_send(socket, composer_mode) do
    a = socket.assigns
    content = HandbeanProbe.WritingPhotoReviews.compose_user_text(a)
    running? = match?(%{running: true}, a.chat)

    cond do
      a.share_send != nil ->
        socket

      composer_mode == :review and running? ->
        Notice.put_error(
          socket,
          gettext("Wait until the current task finishes before generating a review.")
        )

      content == "" and a.pending_attachments == [] ->
        Notice.put_error(socket, gettext("Please enter a message"))

      HandbeanProbe.NativeModelInputs.warning(a) != nil ->
        HandbeanProbe.NativeModelInputs.check(socket)

      true ->
        case Nav.ensure_conversation(socket) do
          {:ok, socket} ->
            case maybe_send_direct_message(socket, content, composer_mode) do
              {:handled, socket} ->
                socket

              :continue ->
                inbound_id = Ecto.UUID.generate()
                deliver_as = socket.assigns[:deliver_mode] || :steer

                case Share.begin_send(socket, inbound_id, deliver_as, composer_mode) do
                  {:ready, socket} ->
                    send_after_intake_pending(socket, inbound_id, deliver_as, composer_mode)

                  {:pending, socket} ->
                    socket
                end
            end

          {:error, _reason} ->
            Notice.put_error(
              socket,
              gettext("Could not create the conversation. Check available storage.")
            )
        end
    end
  end

  defp maybe_send_direct_message(socket, content, :chat) do
    with [_, ref, message] <- Regex.run(~r/\A@([\w.-]+)\s+(\S.*)\z/s, content),
         [] <- socket.assigns.pending_attachments,
         conversation_id when is_binary(conversation_id) <- Nav.current_conversation_id(socket),
         {:ok, children} <- Delegation.status(conversation_id, :list),
         true <- Enum.any?(children, &(ref in [&1.child_conversation_id, &1.subagent_type])) do
      case Delegation.message(conversation_id, ref, message, source: :mobile) do
        {:ok, %{delivery: delivery}} ->
          a = socket.assigns

          socket =
            assign(socket,
              draft: "",
              drafts: NativeWorkspaces.clear_draft(a.drafts, a.workspace, a.chat.conversation)
            )

          note =
            if delivery == :steer,
              do: gettext("Sent to subagent %{ref}.", ref: ref),
              else: gettext("Subagent %{ref} is answering a follow-up.", ref: ref)

          {:handled, Notice.put_info(socket, note)}

        {:error, reason} ->
          reason = if is_binary(reason), do: reason, else: inspect(reason)
          {:handled, Notice.put_error(socket, reason)}
      end
    else
      _ -> :continue
    end
  end

  defp maybe_send_direct_message(_socket, _content, _composer_mode), do: :continue

  @doc "Second half of a send, once any merged share intakes are marked `send_pending`."
  def send_after_intake_pending(socket, inbound_id, deliver_as \\ :steer, composer_mode \\ :chat) do
    a = socket.assigns
    content = HandbeanProbe.WritingPhotoReviews.compose_user_text(a)

    case NativeChat.send_message(a.workspace, a.chat.conversation, content, a.pending_attachments,
           inbound_id: inbound_id,
           deliver_as: deliver_as,
           composer_mode: composer_mode
         ) do
      {:ok, ack} ->
        Platform.cleanup_draft_files(a.pending_attachments)
        chat = %{a.chat | entries: NativeChat.reload_entries(a.chat), running: true}

        chat =
          if ack[:action] == :enqueued do
            NativeChat.note_enqueued(chat, inbound_id, ack[:deliver_as] || deliver_as, %{
              content: content,
              attachments: ack[:attachments] || []
            })
          else
            chat
          end

        socket =
          socket
          |> Share.after_send_ok()
          |> assign(
            chat: chat,
            draft: "",
            drafts: NativeWorkspaces.clear_draft(a.drafts, a.workspace, chat.conversation),
            pending_attachments: [],
            composer_open_id: nil,
            timeline_open: nil,
            notice: nil,
            deliver_mode: :steer,
            last_send_ack: {:acknowledged, ack[:inbound_id] || inbound_id}
          )

        maybe_steer_hint(socket, ack)

      {:error, {:model_input, _, _}} ->
        socket
        |> Share.after_send_failed()
        |> assign(:models, HandbeanProbe.ModelSettings.load(a.workspace))
        |> HandbeanProbe.NativeModelInputs.check()

      {:error, :run_in_progress} ->
        socket
        |> Share.after_send_failed()
        |> Notice.put_error(
          gettext("Wait until the current task finishes before generating a review.")
        )

      {:error, {:skill_unavailable, _}} ->
        socket
        |> Share.after_send_failed()
        |> Notice.put_error(
          gettext("The review rules could not be read from the app package. Nothing was sent.")
        )

      {:error, {:inbound_persist_failed, _}} ->
        socket
        |> Share.after_send_failed()
        |> Notice.put_error(
          gettext("The message could not be saved. Nothing was sent to the model.")
        )

      {:error, _reason} ->
        socket
        |> Share.after_send_failed()
        |> Notice.put_error(
          gettext("Send failed. Check the model configuration and network, then try again.")
        )
    end
  end

  defp maybe_steer_hint(socket, %{action: :enqueued, deliver_as: deliver_as})
       when deliver_as in [:steer, "steer"] do
    if socket.assigns.steer_hint_shown do
      socket
    else
      socket
      |> assign(:steer_hint_shown, true)
      |> Notice.put_info(
        gettext(
          "The message will be inserted at the next step. To wait until this run finishes, switch to “When done”, or write “when you’re done…”."
        )
      )
    end
  end

  defp maybe_steer_hint(socket, _), do: socket

  defp cancel_pending(socket, id) do
    chat = socket.assigns.chat

    if chat do
      conv_id = chat.conversation["id"]
      item = Map.get(chat.pending || %{}, id)

      case Handbean.Agent.Coordinator.delete_pending_message(conv_id, id) do
        :ok ->
          socket
          |> assign(
            :chat,
            NativeChat.drop_pending(%{chat | entries: NativeChat.reload_entries(chat)}, id)
          )
          |> restore_draft(item)
          |> Notice.clear()

        {:error, :not_found} ->
          socket
          |> assign(
            :chat,
            NativeChat.drop_pending(%{chat | entries: NativeChat.reload_entries(chat)}, id)
          )
          |> Notice.put_info(gettext("Already inserted; cannot undo."))

        {:error, _} ->
          Notice.put_error(socket, gettext("Could not undo that message. Please try again."))
      end
    else
      socket
    end
  end

  defp restore_draft(socket, item) when is_map(item) do
    socket
    |> restore_draft_text(item)
    |> restore_draft_attachments(item)
  end

  defp restore_draft(socket, _), do: socket

  defp restore_draft_text(socket, %{content: content})
       when is_binary(content) and content != "" do
    current = socket.assigns.draft || ""

    draft =
      if String.trim(current) == "" do
        content
      else
        String.trim_trailing(current) <> "\n" <> content
      end

    assign(socket, :draft, draft)
  end

  defp restore_draft_text(socket, _), do: socket

  defp restore_draft_attachments(socket, %{attachments: attachments})
       when is_list(attachments) and attachments != [] do
    assign(socket, :pending_attachments, socket.assigns.pending_attachments ++ attachments)
  end

  defp restore_draft_attachments(socket, _), do: socket

  defp resend_pending(socket, id) do
    chat = socket.assigns.chat
    item = chat && Map.get(chat.pending || %{}, id)

    cond do
      is_nil(item) ->
        socket

      item[:status] != :undelivered ->
        socket

      true ->
        content = if is_binary(item[:content]), do: item[:content], else: ""
        attachments = List.wrap(item[:attachments])

        if String.trim(content) == "" and attachments == [] do
          Notice.put_error(socket, gettext("Please enter a message"))
        else
          do_resend_pending(socket, id, item, content, attachments)
        end
    end
  end

  defp do_resend_pending(socket, id, item, content, attachments) do
    a = socket.assigns
    chat = a.chat
    conv = chat.conversation
    deliver_as = item[:deliver_as] || :steer
    inbound_id = Ecto.UUID.generate()

    chat = %{
      chat
      | pending: Handbean.Agent.PendingMessages.put_status(chat.pending, id, :resending)
    }

    socket = assign(socket, :chat, chat)

    case NativeChat.send_message(a.workspace, conv, content, attachments,
           inbound_id: inbound_id,
           deliver_as: deliver_as
         ) do
      {:ok, ack} ->
        finish_resend(socket, id, ack)

      {:error, :images_not_supported} ->
        socket
        |> assign(:chat, restore_undelivered(chat, id))
        |> Notice.put_error(gettext("The current model cannot send images."))

      {:error, _reason} ->
        socket
        |> assign(:chat, restore_undelivered(chat, id))
        |> Notice.put_error(
          gettext("Send failed. Check the model configuration and network, then try again.")
        )
    end
  end

  defp finish_resend(socket, old_id, ack) do
    a = socket.assigns
    chat = a.chat
    conv_id = chat.conversation["id"]
    inbound_id = ack[:inbound_id]

    chat = %{chat | entries: NativeChat.reload_entries(chat), running: true}

    chat =
      if ack[:action] == :enqueued do
        NativeChat.note_enqueued(chat, inbound_id, ack[:deliver_as] || :steer, %{
          content: ack[:content],
          attachments: ack[:attachments] || []
        })
      else
        chat
      end

    {chat, notice} =
      case NativeChat.drop_transcript_entry(conv_id, old_id) do
        :ok ->
          {NativeChat.drop_pending(chat, old_id), nil}

        {:ok, _} ->
          {NativeChat.drop_pending(chat, old_id), nil}

        _ ->
          {NativeChat.drop_pending(chat, old_id),
           gettext("Resent, but the previous copy could not be removed from history.")}
      end

    chat = %{chat | entries: NativeChat.reload_entries(chat)}

    socket =
      socket
      |> assign(
        chat: chat,
        last_send_ack: {:acknowledged, inbound_id}
      )
      |> then(fn socket ->
        if notice, do: Notice.put_error(socket, notice), else: Notice.clear(socket)
      end)

    maybe_steer_hint(socket, ack)
  end

  defp restore_undelivered(chat, id) do
    %{chat | pending: Handbean.Agent.PendingMessages.put_status(chat.pending, id, :undelivered)}
  end

  # ── approval ──

  defp decide(socket, chat, action, scope) do
    a = socket.assigns
    cleared = %{chat | pending_approval: nil, approval_seq: nil}

    case NativeApproval.decide(chat, approval_workspace(a), action, scope, a.approval_snapshots) do
      :ok ->
        socket
        |> cleanup_after_decision(chat, action)
        |> assign(:chat, cleared)
        |> Notice.clear()

      {:ok, :rule_not_saved} ->
        socket
        |> cleanup_after_decision(chat, action)
        |> assign(:chat, cleared)
        |> Notice.put_error(
          gettext("Approval submitted, but the rule could not be saved to the workspace.")
        )

      {:error, _} ->
        Notice.put_error(
          socket,
          gettext("Approval was not submitted. Please try again or reopen the conversation.")
        )
    end
  end

  defp cleanup_after_decision(socket, _chat, :deny) do
    NativeArtifactDelivery.cleanup_bindings(socket, :force)
  end

  defp cleanup_after_decision(socket, chat, :approve) do
    requests = chat.pending_approval["action_requests"] || []

    case Enum.find(requests, &Handbean.ArtifactDelivery.tool?(&1["tool_name"] || "")) do
      nil ->
        socket

      selected ->
        skipped =
          NativeApproval.skipped_android_requests(
            chat.pending_approval,
            selected["tool_call_id"]
          )

        NativeArtifactDelivery.cleanup_skipped_approval_bindings(
          socket,
          chat.conversation["id"],
          skipped
        )
    end
  end

  # ── helpers ──

  defp approval_workspace(assigns) do
    if Nav.free_chat?(assigns), do: nil, else: assigns.workspace
  end

  defp current?(socket, conversation_id) do
    match?(%{conversation: %{"id" => ^conversation_id}}, socket.assigns.chat)
  end

  defp schedule_reload(%{transcript_dirty: true, reload_timer: nil} = projected) do
    ref =
      Process.send_after(
        self(),
        {:reload_transcript, projected.conversation["id"]},
        NativeChat.reload_coalesce_ms()
      )

    %{projected | reload_timer: ref}
  end

  defp schedule_reload(projected), do: projected

  defp settle_stopping(socket, %{running: false}), do: assign(socket, :stopping, false)
  defp settle_stopping(socket, _projected), do: socket
end
