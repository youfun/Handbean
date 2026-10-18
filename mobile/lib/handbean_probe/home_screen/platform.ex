defmodule HandbeanProbe.HomeScreen.Platform do
  @moduledoc """
  Composer attachments and the typed `HandbeanProbe.Platform` request cycle:
  begin (import / photo picker), result (attachment, batch, cancelled, error),
  deadline expiry, and draft image cards.

  The C `engine_result` envelope is already decoded to
  `HandbeanProbe.Bridge.Inbound.EngineResult` when it reaches `handle/2`.
  Requests are correlated through `HandbeanProbe.HomeScreen.Requests`
  (`HandbeanProbe.PendingRequests`, scope `:composer`): the wire `generation`
  must equal the registered one and the composer must not have been reset
  since, otherwise the result is dropped and its importer-owned files are
  released. Delivery kinds (`open_url`, exports, snapshots) are routed to
  `HandbeanProbe.NativeArtifactDelivery.handle_result/3`.

  File removal (`Platform.safe_rm_controlled/1`) runs off-screen and reports
  `{:draft_files_removed, nil, :ok}`.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 2, assign: 3]

  require Logger

  alias HandbeanProbe.Bridge.{Inbound, Payload}
  alias HandbeanProbe.HomeScreen.{Async, Notice, Requests}
  alias HandbeanProbe.{NativeArtifactDelivery, NativeComposer, PendingRequests}
  alias HandbeanProbe.Platform.Request

  # ── dispatch ──

  def handle({:change, :artifact_path, text}, socket), do: assign(socket, :artifact_path, text)
  def handle({:change, :open_url_draft, text}, socket), do: assign(socket, :open_url_draft, text)

  def handle({:tap, {:platform, :begin, kind}}, socket), do: begin(socket, kind, %{})
  def handle({:platform, :begin, kind}, socket), do: begin(socket, kind, %{})
  def handle({:platform, :begin, kind, payload}, socket), do: begin(socket, kind, payload)

  def handle({:platform, :result, request_id, result}, socket),
    do: result(socket, request_id, result)

  def handle({:engine_result, %Inbound.EngineResult{} = wire}, socket),
    do: result(socket, wire.request_id, wire.body, wire.generation)

  def handle({:tap, {:remove_attachment, id}}, socket) do
    # Draft attachments are string-keyed (`add_attachment/2`).
    {removed, kept} = Enum.split_with(socket.assigns.pending_attachments, &(&1["id"] == id))

    cleanup_draft_files(removed)
    open_id = socket.assigns.composer_open_id

    assign(socket,
      pending_attachments: kept,
      composer_open_id: if(open_id == id, do: nil, else: open_id)
    )
    |> HandbeanProbe.NativeModelInputs.check()
  end

  def handle({:tap, {:open_draft_image, id}}, socket) do
    next = if socket.assigns.composer_open_id == id, do: nil, else: id
    assign(socket, composer_open_id: next, timeline_open: nil)
  end

  def handle({:tap, :close_draft_image}, socket), do: assign(socket, :composer_open_id, nil)

  def handle({:tap, {:open_sent_image, message_id, attachment_id}}, socket) do
    current = socket.assigns.timeline_open
    same = match?(%{message_id: ^message_id, attachment_id: ^attachment_id}, current)
    next = if same, do: nil, else: %{message_id: message_id, attachment_id: attachment_id}
    assign(socket, timeline_open: next, composer_open_id: nil)
  end

  def handle({:tap, :close_sent_image}, socket), do: assign(socket, :timeline_open, nil)

  # ── begin / result ──

  defp begin(socket, :pick_photos, payload) when is_map(payload) do
    socket = HandbeanProbe.NativeModelInputs.check(socket, ["image"])

    if socket.assigns.input_warning,
      do: socket,
      else: start_request(socket, :pick_photos, payload)
  end

  defp begin(socket, :import, payload) when is_map(payload) do
    start_request(socket, :import, payload)
  end

  defp begin(socket, _kind, _payload), do: Notice.put_error(socket, platform_error(:unknown_op))

  defp start_request(socket, kind, payload) do
    ctx = NativeComposer.context(socket)

    with {:ok, req} <- Request.for_kind(kind, ctx, self(), payload),
         {:ok, _} <- HandbeanProbe.Platform.start(req) do
      Requests.track(socket, ctx.request_id, kind, ctx)
    else
      {:error, reason} -> Notice.put_error(socket, platform_error(reason))
    end
  end

  # `wire_generation` is what the host echoed (`nil` for the in-BEAM
  # `{:platform, :result, ...}` path, which is only checked for supersession).
  defp result(socket, request_id, result, wire_generation \\ :any) do
    case Requests.take(socket, request_id, wire_generation || :any) do
      {:ok, %PendingRequests.Entry{ctx: ctx}, socket} ->
        if ctx.kind in NativeArtifactDelivery.delivery_kinds() do
          NativeArtifactDelivery.handle_result(socket, ctx, result)
        else
          apply_result(socket, result)
        end

      {:error, reason, socket} ->
        Logger.debug("[platform] result for #{request_id} dropped: #{inspect(reason)}")
        discard_stale(socket, request_id, wire_generation, result)
        socket
    end
  end

  @doc """
  A registered request passed its deadline: tell the host to cancel it, then
  finish it as `{:error, :timeout}` (delivery kinds) or show a notice.
  """
  def handle_timeout(socket, %PendingRequests.Entry{ref: request_id, ctx: ctx} = entry)
      when is_binary(request_id) do
    _ = HandbeanProbe.Platform.cancel(self(), request_id, entry.generation)

    if is_map(ctx) and ctx[:kind] in NativeArtifactDelivery.delivery_kinds() do
      NativeArtifactDelivery.handle_result(socket, ctx, {:error, :timeout})
    else
      Notice.put_error(socket, platform_error(:timeout))
    end
  end

  def handle_timeout(socket, %PendingRequests.Entry{kind: kind}) do
    Logger.warning("[platform] off-screen task #{kind} passed its deadline")
    Notice.put_error(socket, platform_error(:timeout))
  end

  defp apply_result(socket, {:ok, attachment}), do: add_attachment(socket, attachment)

  defp apply_result(socket, {:ok_batch, attachments, errors}) do
    socket = Enum.reduce(attachments, socket, &add_attachment(&2, &1))
    if errors == [], do: socket, else: Notice.put_error(socket, batch_error(errors))
  end

  defp apply_result(socket, :cancelled), do: socket

  defp apply_result(socket, {:error, reason}),
    do: Notice.put_error(socket, platform_error(reason))

  # ── attachments ──

  def add_attachment(socket, attachment) do
    att = Payload.attachment(attachment)
    current = socket.assigns.pending_attachments

    case Handbean.Attachments.validate_batch(current ++ [att]) do
      :ok ->
        socket
        |> assign(:pending_attachments, current ++ [att])
        |> Notice.clear()
        |> HandbeanProbe.NativeModelInputs.check()

      {:error, reason} ->
        Notice.put_error(socket, platform_error(reason))
    end
  end

  @doc "Release importer-owned draft files off-screen. Share-sourced files stay."
  def cleanup_draft_files([]), do: :ok

  def cleanup_draft_files(attachments) when is_list(attachments) do
    paths =
      attachments
      |> Enum.map(&owned_path/1)
      |> Enum.reject(&is_nil/1)

    if paths != [] do
      _ =
        Async.fire(:draft_files_removed, fn ->
          Enum.each(paths, &HandbeanProbe.Platform.safe_rm_controlled/1)
        end)
    end

    :ok
  end

  defp owned_path(att) when is_map(att) do
    att = Payload.attachment(att)
    source = att["source"]
    path = att["controlled_path"]
    if source in [:share, "share"] or not is_binary(path), do: nil, else: path
  end

  defp owned_path(_), do: nil

  defp discard_stale(socket, request_id, wire_generation, {:ok, result})
       when is_map(result) do
    snapshot = Inbound.snapshot(result)
    owner_request_id = snapshot.owner_request_id || request_id

    generation =
      if is_integer(wire_generation),
        do: wire_generation,
        else: Requests.composer_generation(socket)

    if is_binary(snapshot.snapshot_id) and is_binary(owner_request_id) do
      _ =
        HandbeanProbe.Platform.cleanup_snapshot(
          self(),
          Ecto.UUID.generate(),
          generation,
          snapshot.snapshot_id,
          owner_request_id
        )

      :ok
    else
      cleanup_draft_files([result])
    end
  end

  defp discard_stale(_socket, _request_id, _wire_generation, {:ok_batch, attachments, _}),
    do: cleanup_draft_files(attachments)

  defp discard_stale(_socket, _request_id, _wire_generation, _result), do: :ok

  # ── copy ──

  def platform_error(:too_many_attachments), do: gettext("At most 4 attachments")
  def platform_error(:unsupported_type), do: gettext("Unsupported file type")
  def platform_error(:cancelled), do: nil
  def platform_error(:unknown_op), do: gettext("This entry point is not available")

  def platform_error(:timeout),
    do: gettext("The system operation did not answer in time and was cancelled.")

  def platform_error(reason),
    do: gettext("Attachment not added: %{reason}", reason: inspect(reason))

  def batch_error(errors) do
    reasons =
      errors
      |> Enum.map(fn
        %{"reason" => reason} -> reason
        reason when is_binary(reason) -> reason
        reason -> inspect(reason)
      end)
      |> Enum.uniq()
      |> Enum.join("; ")

    gettext("Some material was not added: %{reasons}", reasons: reasons)
  end
end
