defmodule HandbeanWeb.ConversationHandoff do
  @moduledoc "Read-only projection of persisted handoffs. Rendering never dispatches work."
  use HandbeanWeb, :html

  attr :entry, :map, required: true
  attr :conversation_id, :string, required: true
  attr :workspace_id, :string, required: true
  attr :time_zone, :string, default: nil

  def card(assigns) do
    context = %{conversation_id: assigns.conversation_id, workspace_id: assigns.workspace_id}
    origin = assigns.entry["origin"] || %{}
    target_id = assigns.entry["target"] || origin["conversation_id"]

    target =
      case Handbean.Conversations.authorize(context, target_id) do
        {:ok, target} -> target
        _ -> nil
      end

    messages =
      if target do
        [assigns.conversation_id, target_id]
        |> Enum.flat_map(fn id ->
          case Handbean.ConversationTranscriptStore.list(id) do
            {:ok, entries} ->
              Enum.filter(entries, fn e ->
                get_in(e, ["origin", "kind"]) == "conversation" and
                  get_in(e, ["origin", "conversation_id"]) in [assigns.conversation_id, target_id] and
                  association(e) == association(assigns.entry)
              end)

            _ ->
              []
          end
        end)
        |> Enum.sort_by(&{get_in(&1, ["origin", "sent_at"]) || &1["created_at"] || "", &1["id"]})
        |> Enum.take(-20)
      else
        []
      end

    viewer =
      case Handbean.ConversationStore.get_metadata(assigns.conversation_id) do
        {:ok, meta} -> meta
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:target, target)
      |> assign(:messages, messages)
      |> assign(:handoff_id, association(assigns.entry))
      |> assign(:important, origin["important"] == true)
      |> assign(:access_label, access_label(viewer, target))

    ~H"""
    <section
      class="rounded-lg border border-base-300 bg-base-200/50 p-3 text-sm"
      data-conversation-handoff={@handoff_id}
      data-conversation-access={@access_label}
    >
      <div class="flex flex-wrap items-center gap-2 text-xs opacity-80">
        <span>↗ {if @important, do: "Conversation result", else: "Conversation handoff"}</span>
        <a
          :if={@target}
          class="underline font-medium"
          href={"/w/#{URI.encode_www_form(@workspace_id)}/c/#{URI.encode_www_form(@target["id"])}"}
        >
          {String.slice(@target["title"] || "Conversation", 0, 200)}
        </a>
        <span :if={!@target}>Source unavailable</span>
        <span :if={@entry["delivery_status"]}>{@entry["delivery_status"]} · not completion</span>
      </div>
      <div :if={@important && @target} class="mt-2 break-words">
        <div
          id={"conversation-result-md-#{@entry["id"]}"}
          data-entry-id={@entry["id"]}
          data-source={@entry["content"] || ""}
          data-final="true"
          data-streaming="false"
          class="msg-markdown-wrapper"
          phx-hook="StreamingMarkdown"
        >
          <button class="msg-copy-btn" title="Copy" aria-label="Copy">
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2 2v1"></path>
            </svg>
          </button>
          <div
            id={"conversation-result-md-content-#{@entry["id"]}"}
            data-markdown-target
            phx-update="ignore"
            class="markdown-body prose prose-sm max-w-none break-words"
          >
            <div class="markdown-noscript-fallback">{@entry["content"]}</div>
            <noscript>{@entry["content"]}</noscript>
          </div>
        </div>
      </div>
      <details :if={@target && !@important} class="mt-2">
        <summary class="thread-handoff-summary disclosure-summary cursor-pointer">
          <span>View exchange<span :if={@access_label}> ({@access_label})</span></span>
          <span class="disclosure-chevron" aria-hidden="true">⌄</span>
        </summary>
        <p class="mt-2 text-xs opacity-60">
          Latest 20 reports. Open the conversation to read all messages or give instructions.
        </p>
        <p :if={@messages == []} class="mt-2 whitespace-pre-wrap break-words">
          {@entry["content"] || "No confirmed delivery yet."}
        </p>
        <article :for={message <- @messages} class="mt-3 border-l-2 border-base-300 pl-3">
          <span class="text-xs opacity-60">
            {if get_in(message, ["origin", "conversation_id"]) == @conversation_id,
              do: "Sent",
              else: "Received"} ·
            <time
              datetime={message["created_at"]}
              data-time-zone={@time_zone || "Etc/UTC"}
              title={@time_zone || "Etc/UTC"}
            >
              {format_local_time(message["created_at"], @time_zone)}
            </time>
          </span>
          <p class="whitespace-pre-wrap break-words">{body(message)}</p>
        </article>
      </details>
    </section>
    """
  end

  # The label is the delegated child's access, whether this card is on the parent or the child.
  # The exchange itself stays a projection: expanding it never dispatches.
  defp access_label(viewer, target) do
    case delegated_child(viewer, target) do
      %{"collaboration" => %{"read_only" => false}} ->
        "write"

      %{"collaboration" => %{"read_only" => true}} ->
        "read-only"

      _ ->
        nil
    end
  end

  defp delegated_child(viewer, target) do
    cond do
      delegated?(target) -> target
      delegated?(viewer) -> viewer
      true -> nil
    end
  end

  defp delegated?(meta) when is_map(meta) do
    is_binary(Handbean.ConversationStore.parent_conversation_id(meta)) and
      is_boolean(get_in(meta, ["collaboration", "read_only"]))
  end

  defp delegated?(_), do: false

  defp format_local_time(value, time_zone) when is_binary(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, local} <- DateTime.shift_zone(datetime, time_zone || "Etc/UTC") do
      Calendar.strftime(local, "%Y-%m-%d %H:%M:%S")
    else
      _ -> value
    end
  end

  defp format_local_time(value, _time_zone), do: value

  defp body(message) do
    text = message["content"] || ""

    String.slice(text, 0, 2000) <>
      if(String.length(text) > 2000, do: "… (open conversation for full message)", else: "")
  end

  def show?(entry, timeline) do
    origin = entry["origin"] || %{}
    peer = entry["target"] || origin["conversation_id"]
    handoff? = entry["content_type"] == "conversation_handoff" or origin["kind"] == "conversation"

    first =
      Enum.find(timeline, fn item ->
        (item["content_type"] == "conversation_handoff" or
           get_in(item, ["origin", "kind"]) == "conversation") and
          (item["target"] == peer or get_in(item, ["origin", "conversation_id"]) == peer) and
          association(item) == association(entry)
      end)

    handoff? and (origin["important"] == true or is_nil(first) or first["id"] == entry["id"])
  end

  # Older records have no task association: never guess one from the peer alone.
  defp association(entry) do
    entry["handoff_id"] || get_in(entry, ["origin", "handoff_id"]) ||
      get_in(entry, ["origin", "request_id"]) || entry["id"]
  end
end
