defmodule HandbeanWeb.WorkspaceLive.ConversationSearchTest do
  use HandbeanWeb.WorkspaceLiveCase

  alias Handbean.PubSub.AgentEvent
  alias Handbean.{ConversationStore, ConversationTranscriptStore}
  alias HandbeanWeb.WorkspaceLive.Composer

  test "searches visible persisted text and opens the exact old message window", %{conn: conn} do
    {:ok, conversation} =
      ConversationStore.create("default",
        id: "search-live-#{System.unique_integer([:positive])}",
        title: "Search live fixture"
      )

    for index <- 1..130 do
      content = if index == 5, do: "定位旧消息 中文针", else: "ordinary message #{index}"

      assert {:ok, _} =
               ConversationTranscriptStore.append(conversation["id"], %{
                 "id" => "search-live-entry-#{index}",
                 "role" => "user",
                 "content_type" => "user_msg",
                 "message_type" => "user",
                 "direction" => "inbound",
                 "content" => content
               })
    end

    {:ok, view, _html} = live(conn, "/")

    view |> element("#open-conversation-search") |> render_click()
    render_async(view)

    _html =
      view
      |> form("#conversation-search-form", %{
        "search" => %{"query" => "中文针", "content" => "all", "range" => "all"}
      })
      |> render_change()

    render_async(view)
    assert render(view) =~ "定位旧消息 中文针"

    view
    |> element("button[phx-value-entry_id='search-live-entry-5']")
    |> render_click()

    assert_patch(view, "/w/default/c/#{conversation["id"]}")
    assert_push_event(view, "set-conversation-entry-hash", %{id: "search-live-entry-5"})
    html = render(view)
    assert html =~ "Viewing a search result in conversation history"
    assert html =~ "定位旧消息 中文针"
    refute html =~ "ordinary message 130"
  end

  test "an around window at the tail can load entries appended by runtime", %{conn: conn} do
    {:ok, conversation} =
      ConversationStore.create("default",
        id: "search-tail-#{System.unique_integer([:positive])}",
        title: "Tail boundary fixture"
      )

    for index <- 1..30 do
      content = if index == 30, do: "tail anchor needle", else: "tail history #{index}"

      assert {:ok, _} =
               ConversationTranscriptStore.append(conversation["id"], %{
                 "id" => "tail-entry-#{index}",
                 "role" => "user",
                 "content_type" => "user_msg",
                 "message_type" => "user",
                 "direction" => "inbound",
                 "content" => content
               })
    end

    {:ok, view, _html} = live(conn, "/")
    view |> element("#open-conversation-search") |> render_click()
    render_async(view)

    view
    |> form("#conversation-search-form", %{
      "search" => %{"query" => "tail anchor needle", "content" => "all", "range" => "all"}
    })
    |> render_change()

    render_async(view)

    view
    |> element("button[phx-value-entry_id='tail-entry-30']")
    |> render_click()

    refute has_element?(view, "button[phx-click='load_newer_history']")

    timeline_before_pending = :sys.get_state(view.pid).socket.assigns.timeline

    pending = %{
      "tail-entry-31" => %{
        id: "tail-entry-31",
        content: "newly persisted tail",
        status: :queued
      }
    }

    :sys.replace_state(view.pid, fn state ->
      %{state | socket: Composer.assign_pending(state.socket, pending)}
    end)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.pending_messages == pending
    assert assigns.timeline == timeline_before_pending
    refute Enum.any?(assigns.timeline, &(&1["id"] == "tail-entry-31"))

    assert {:ok, _} =
             ConversationTranscriptStore.append(conversation["id"], %{
               "id" => "tail-entry-31",
               "role" => "assistant",
               "content_type" => "assistant_msg",
               "message_type" => "assistant",
               "direction" => "outbound",
               "phase" => "final",
               "content" => "newly persisted tail"
             })

    send(
      view.pid,
      {:agent_event,
       %AgentEvent{
         topic: "session:#{conversation["id"]}",
         seq: 1,
         kind: :message_delta,
         payload: %{
           transcript_id: "tail-entry-31",
           text_offset: 0,
           text: "newly persisted tail"
         }
       }}
    )

    assert render(view) =~ "Load newer messages"
    refute render(view) =~ "newly persisted tail"

    view |> element("button[phx-click='load_newer_history']") |> render_click()
    assert render(view) =~ "newly persisted tail"

    send(
      view.pid,
      {:agent_event,
       %AgentEvent{
         topic: "session:#{conversation["id"]}",
         seq: 2,
         kind: :run_end,
         payload: %{status: "completed", turns: 1}
       }}
    )

    assert render(view) =~ "Viewing a search result in conversation history"

    view |> element("button[phx-click='return_to_latest_history']") |> render_click()
    assert render(view) =~ "newly persisted tail"
    refute render(view) =~ "Viewing a search result in conversation history"
  end

  test "a stale load-more cannot cancel a replacement query", %{conn: conn} do
    for index <- 1..13 do
      assert {:ok, _} =
               ConversationStore.create_free(
                 id: "search-stale-alpha-#{index}-#{System.unique_integer([:positive])}",
                 title: "Alpha stale result #{index}"
               )
    end

    assert {:ok, replacement} =
             ConversationStore.create_free(
               id: "search-stale-beta-#{System.unique_integer([:positive])}",
               title: "Beta replacement result"
             )

    {:ok, view, _html} = live(conn, "/")
    view |> element("#open-conversation-search") |> render_click()
    render_async(view)

    view
    |> form("#conversation-search-form", %{
      "search" => %{"query" => "Alpha stale", "content" => "all", "range" => "all"}
    })
    |> render_change()

    render_async(view)
    alpha_search = :sys.get_state(view.pid).socket.assigns.conversation_search
    assert is_binary(alpha_search.next_cursor)

    :sys.replace_state(view.pid, fn state ->
      search = %{
        state.socket.assigns.conversation_search
        | query: "Beta replacement",
          loading?: true,
          revision: alpha_search.revision + 1
      }

      %{state | socket: Phoenix.Component.assign(state.socket, :conversation_search, search)}
    end)

    render_hook(view, "load_more_conversation_search", %{})
    blocked = :sys.get_state(view.pid).socket.assigns.conversation_search
    assert blocked.loading?
    assert blocked.revision == alpha_search.revision + 1
    assert blocked.next_cursor == alpha_search.next_cursor
    assert blocked.results == alpha_search.results

    :sys.replace_state(view.pid, fn state ->
      %{
        state
        | socket: Phoenix.Component.assign(state.socket, :conversation_search, alpha_search)
      }
    end)

    view
    |> form("#conversation-search-form", %{
      "search" => %{"query" => "Beta replacement", "content" => "all", "range" => "all"}
    })
    |> render_change()

    render_async(view)

    search = :sys.get_state(view.pid).socket.assigns.conversation_search
    assert search.next_cursor == nil
    assert search.results_query == "Beta replacement"
    assert Enum.map(search.results, & &1.conversation_id) == [replacement["id"]]
    refute search.loading?
  end

  test "mobile header opens search and closing requests focus restoration", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(
             view,
             "#mobile-open-conversation-search[phx-click='open_conversation_search'][aria-haspopup='dialog']"
           )

    view |> element("#mobile-open-conversation-search") |> render_click()

    assert has_element?(view, "#conversation-search-overlay:not([hidden])")
    assert_push_event(view, "focus-conversation-search", %{})

    view |> element("#conversation-search-close") |> render_click()

    assert has_element?(view, "#conversation-search-overlay[hidden]")
    assert_push_event(view, "restore-conversation-search-focus", %{})
  end

  test "closing and reopening preserves query, filters, and loaded results", %{conn: conn} do
    {:ok, conversation} =
      ConversationStore.create_free(
        id: "search-preserve-#{System.unique_integer([:positive])}",
        title: "Preserved palette result"
      )

    {:ok, view, _html} = live(conn, "/")
    view |> element("#open-conversation-search") |> render_click()
    render_async(view)

    view
    |> element("button[phx-click='conversation_search_content'][phx-value-content='title']")
    |> render_click()

    view
    |> form("#conversation-search-form", %{
      "search" => %{"query" => "Preserved", "content" => "title", "range" => "free"}
    })
    |> render_change()

    render_async(view)
    assert render(view) =~ conversation["title"]

    view |> element("#conversation-search-close") |> render_click()
    view |> element("#open-conversation-search") |> render_click()

    html = render(view)
    assert html =~ ~s(value="Preserved")
    assert html =~ conversation["title"]
    assert html =~ ~s(value="free" selected)
  end
end
