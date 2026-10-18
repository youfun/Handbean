defmodule HandbeanProbe.NativeComposer do
  @moduledoc """
  Composer projection: draft text, compact image thumbs, and name chips.
  HomeScreen routes intents. Compose owns selection; this module never stores
  TextFieldValue. Image nodes pass only a controlled local path — never bytes.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.HomeScreen.Requests
  alias HandbeanProbe.NativeLocalImage

  @doc "Platform request context bound to the current composer generation."
  def context(socket) do
    conversation_id =
      case socket.assigns.chat do
        %{conversation: %{"id" => id}} -> id
        _ -> nil
      end

    %{
      request_id: Ecto.UUID.generate(),
      composer_generation: Requests.composer_generation(socket),
      workspace_id: socket.assigns.workspace["id"],
      conversation_id: conversation_id
    }
  end

  @doc """
  The single composer of the native shell: open image card, name chips and
  the input row (draft field, thumbs, add, stop while running, send).
  """
  def render_field(assigns, running) do
    attachments = assigns.pending_attachments
    open_id = Map.get(assigns, :composer_open_id)
    deliver_mode = Map.get(assigns, :deliver_mode, :steer)

    node(
      :column,
      [fill_width: true],
      [
        render_open_card(attachments, open_id),
        render_chips(attachments),
        if(running, do: deliver_chip(deliver_mode)),
        node(
          :row,
          [
            fill_width: true,
            background: color(:card),
            border_color: color(:border),
            border_width: 1,
            corner_radius: 14,
            padding: 8
          ],
          [
            HandbeanProbe.NativeUI.node(:text_field,
              id: "draft",
              value: assigns.draft,
              placeholder:
                if(running,
                  do:
                    gettext(
                      "Running: send inserts next · optionally wait until this run finishes"
                    ),
                  else: gettext("Send a message…")
                ),
              background: color(:card),
              text_color: color(:ink),
              placeholder_color: color(:muted),
              plain: true,
              multiline: true,
              weight: 1,
              padding: 6,
              on_change: {self(), :draft},
              on_submit: {self(), :send},
              return_key: "send"
            ),
            render_thumbs(attachments),
            icon("add", {:page, :attachments}),
            if(running, do: icon("close", :stop)),
            icon("forward", :send)
          ]
        )
      ]
    )
  end

  defp deliver_chip(:follow_up) do
    button(gettext("When done ▾"), :toggle_deliver_mode,
      text_size: 12,
      padding: 6,
      background: color(:control)
    )
  end

  defp deliver_chip(_steer) do
    button(gettext("Insert next ▾"), :toggle_deliver_mode,
      text_size: 12,
      padding: 6,
      background: color(:control)
    )
  end

  def render_entries(assigns \\ %{}) do
    HandbeanProbe.NativeArtifactDelivery.render_entries(assigns)
  end

  def render_chips([]), do: nil

  def render_chips(attachments) do
    chips =
      attachments
      |> Enum.reject(&NativeLocalImage.image_attachment?/1)
      |> Enum.map(fn att ->
        id = att_id(att)
        name = att_name(att)

        row([
          text(name, weight: 1, text_size: 12),
          button(gettext("Remove"), {:remove_attachment, id}, text_size: 11, padding: 6)
        ])
      end)

    if chips == [], do: nil, else: node(:column, [fill_width: true, padding_bottom: 6], chips)
  end

  def render_thumbs(attachments) when attachments == [] or attachments == nil, do: nil

  def render_thumbs(attachments) do
    thumbs =
      attachments
      |> Enum.filter(&NativeLocalImage.image_attachment?/1)
      |> Enum.map(&thumb_node/1)

    if thumbs == [], do: nil, else: node(:row, [align: "center"], thumbs)
  end

  def render_open_card(_attachments, open_id) when open_id in [nil, ""], do: nil

  def render_open_card(attachments, open_id) do
    case Enum.find(attachments, &(att_id(&1) == open_id)) do
      nil ->
        nil

      att ->
        name = att_name(att)
        type = att_type(att)

        node(
          :column,
          [
            fill_width: true,
            background: color(:card),
            border_color: color(:border),
            border_width: 1,
            corner_radius: 12,
            padding: 10,
            padding_bottom: 8
          ],
          [
            row([
              text(name, weight: 1, text_size: 13),
              text(type, text_size: 11, text_color: color(:muted))
            ]),
            NativeLocalImage.card_image(NativeLocalImage.draft_src(att), name),
            actions_row([
              button(gettext("Close"), :close_draft_image, text_size: 11, padding: 6),
              button(gettext("Remove"), {:remove_attachment, att_id(att)},
                text_size: 11,
                padding: 6
              )
            ])
          ]
        )
    end
  end

  defp thumb_node(att) do
    NativeLocalImage.thumb(NativeLocalImage.draft_src(att), NativeLocalImage.att_name(att),
      on_tap: {self(), {:open_draft_image, NativeLocalImage.att_id(att)}},
      id: "composer-thumb-#{NativeLocalImage.att_id(att)}"
    )
  end

  defdelegate image_attachment?(att), to: NativeLocalImage
  defdelegate local_image_src(att), to: NativeLocalImage, as: :draft_src
  defdelegate local_file_src?(path), to: NativeLocalImage
  defdelegate att_id(att), to: NativeLocalImage
  defdelegate att_name(att), to: NativeLocalImage
  defdelegate att_type(att), to: NativeLocalImage, as: :mime
end
