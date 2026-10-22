defmodule Handbean.Conversations.UserSearchTest do
  use Handbean.DataCase, async: false

  import Ecto.Query

  alias Handbean.Conversations.UserSearch
  alias Handbean.Conversations.UserSearch.Scope
  alias Handbean.Agent.TranscriptPersistence.Entry, as: PersistenceEntry
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Conversations, Repo}
  alias Handbean.Storage.Conversation

  setup do
    scope = Scope.new(["workspace-a", "workspace-b"], true)
    %{scope: scope}
  end

  test "searches title, trusted user text, and settled assistant text across workspace and free chat",
       %{
         scope: scope
       } do
    {:ok, title} = ConversationStore.create("workspace-a", id: "search-title", title: "权限设计")
    {:ok, user} = ConversationStore.create("workspace-b", id: "search-user", title: "User")
    {:ok, assistant} = ConversationStore.create_free(id: "search-assistant", title: "Free")

    append(user["id"], %{
      "id" => "user-hit",
      "role" => "user",
      "content_type" => "user_msg",
      "message_type" => "user",
      "direction" => "inbound",
      "content" => "中文权限输入"
    })

    append(assistant["id"], %{
      "id" => "assistant-hit",
      "role" => "assistant",
      "content_type" => "assistant_msg",
      "message_type" => "assistant",
      "direction" => "outbound",
      "phase" => "commentary",
      "status" => "interrupted",
      "content" => "Permission 权限 reply"
    })

    assert {:ok, %{results: results, incomplete: false}} =
             Conversations.search_user_visible(%{"query" => "权限"}, scope)

    assert MapSet.new(Enum.map(results, & &1.conversation_id)) ==
             MapSet.new([title["id"], user["id"], assistant["id"]])

    assert Enum.find(results, &(&1.conversation_id == title["id"])).title_match

    assert [%{source: "user", entry_id: "user-hit"}] =
             Enum.find(results, &(&1.conversation_id == user["id"])).matches

    assert [%{source: "assistant", entry_id: "assistant-hit"}] =
             Enum.find(results, &(&1.conversation_id == assistant["id"])).matches

    assert {:ok, %{results: [%{conversation_id: "search-user"}]}} =
             UserSearch.search(%{"query" => "中文", "content" => "user"}, scope)

    assert {:ok, %{results: [%{conversation_id: "search-assistant"}]}} =
             UserSearch.search(%{"query" => "PERMISSION", "content" => "assistant"}, scope)
  end

  test "supports short and literal queries plus partially populated legacy envelopes", %{
    scope: scope
  } do
    {:ok, conversation} =
      ConversationStore.create("workspace-a", id: "search-literal", title: "Literal")

    append(conversation["id"], %{
      "id" => "partial-user",
      "role" => "user",
      "content_type" => "user_msg",
      "content" => "一 %_ lib/a.ex"
    })

    append(conversation["id"], %{
      "id" => "partial-assistant",
      "role" => "assistant",
      "content_type" => "assistant_msg",
      "message_type" => "assistant",
      "content" => "二 CODE/path.ex"
    })

    append(conversation["id"], %{
      "id" => "role-only-legacy",
      "role" => "user",
      "content" => "legacy punctuation a_b%"
    })

    for {query, entry_id} <- [
          {"一", "partial-user"},
          {"%_", "partial-user"},
          {"lib/a.ex", "partial-user"},
          {"code/PATH.EX", "partial-assistant"},
          {"a_b%", "role-only-legacy"}
        ] do
      assert {:ok, %{results: [%{matches: matches}]}} =
               UserSearch.search(%{"query" => query}, scope)

      assert Enum.any?(matches, &(&1.entry_id == entry_id))
    end
  end

  test "fails closed for inaccessible conversations and internal transcript records", %{
    scope: scope
  } do
    {:ok, visible} =
      ConversationStore.create("workspace-a", id: "search-visible", title: "Visible")

    {:ok, foreign} = ConversationStore.create("foreign", id: "search-foreign", title: "needle")

    {:ok, internal} =
      ConversationStore.create("workspace-a",
        id: "search-internal",
        title: "needle",
        visibility: "internal"
      )

    {:ok, pending} =
      ConversationStore.create("workspace-a", id: "search-pending", title: "needle")

    Repo.update_all(from(c in Conversation, where: c.id == ^pending["id"]),
      set: [status: "pending_delete"]
    )

    rejected = [
      %{"id" => "tool", "role" => "tool", "content_type" => "tool", "content" => "needle"},
      %{
        "id" => "system",
        "role" => "system",
        "content_type" => "system_msg",
        "content" => "needle"
      },
      %{
        "id" => "thinking",
        "role" => "assistant",
        "content_type" => "model_compaction",
        "content" => "needle"
      },
      %{
        "id" => "running",
        "role" => "assistant",
        "content_type" => "assistant_msg",
        "status" => "streaming",
        "content" => "needle"
      },
      %{
        "id" => "conflict",
        "role" => "user",
        "content_type" => "user_msg",
        "direction" => "internal",
        "content" => "needle"
      },
      %{
        "id" => "handoff",
        "role" => "user",
        "content_type" => "user_msg",
        "content" => "needle",
        "origin" => %{"kind" => "conversation"}
      },
      %{
        "id" => "legacy-report",
        "role" => "user",
        "content_type" => "user_msg",
        "content" => "Delegated report (requires parent review): needle"
      },
      %{
        "id" => "background-report",
        "role" => "user",
        "content_type" => "user_msg",
        "content" => "Background subagent report for child_conversation_id x: needle"
      },
      %{
        "id" => "reasoning",
        "role" => "assistant",
        "content_type" => "assistant_msg",
        "phase" => "reasoning",
        "content" => "needle"
      }
    ]

    synthetic =
      PersistenceEntry.inbound(
        visible["id"],
        "needle from synthetic report",
        [source: :delegation, channel: :internal],
        1,
        "actual-delegation-report"
      )

    Enum.each([synthetic | rejected], &append(visible["id"], &1))

    append(visible["id"], %{
      "id" => "secret",
      "role" => "assistant",
      "content_type" => "assistant_msg",
      "content" => "api_key=sk-abcdefghijklmnopqrstuvwxyz"
    })

    assert {:ok, %{results: []}} = UserSearch.search(%{"query" => "needle"}, scope)

    append(visible["id"], %{
      "id" => "workspace-command-reply",
      "role" => "assistant",
      "content_type" => "assistant_msg",
      "message_type" => "assistant",
      "direction" => "outbound",
      "phase" => "final",
      "content" => "workspace command visible reply",
      "source" => "workspace_command",
      "channel" => "internal",
      "origin" => %{"kind" => "workspace_command"}
    })

    assert {:ok, %{results: [%{matches: workspace_matches}]}} =
             UserSearch.search(%{"query" => "workspace command visible"}, scope)

    assert Enum.any?(workspace_matches, &(&1.entry_id == "workspace-command-reply"))

    assert {:ok, %{results: []}} =
             UserSearch.search(%{"query" => "abcdefghijklmnopqrstuvwxyz"}, scope)

    for id <- [
          "tool",
          "system",
          "thinking",
          "running",
          "conflict",
          "handoff",
          "legacy-report",
          "background-report",
          "reasoning",
          "actual-delegation-report"
        ] do
      assert {:error, :entry_unavailable} = UserSearch.authorize_hit(scope, visible["id"], id)
    end

    for id <- [foreign["id"], internal["id"], pending["id"]] do
      assert {:error, :not_accessible} = UserSearch.authorize_hit(scope, id)
    end
  end

  test "range, keyset pagination, live deletion, free-only scope, and scan budgets are explicit",
       %{
         scope: scope
       } do
    timestamp = ~U[2026-01-01 00:00:00.000000Z]

    for {id, workspace} <- [
          {"page-c", "workspace-a"},
          {"page-b", "workspace-b"},
          {"page-a", "workspace-a"}
        ] do
      {:ok, _} = ConversationStore.create(workspace, id: id, title: "page match")
      Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [updated_at: timestamp])
    end

    {:ok, _free} = ConversationStore.create_free(id: "page-free", title: "page match")

    assert {:ok, %{results: [first], next_cursor: cursor}} =
             UserSearch.search(%{"query" => "page", "limit" => 1}, scope)

    assert is_binary(cursor)

    assert {:ok, %{results: [second]}} =
             UserSearch.search(%{"query" => "page", "limit" => 1, "cursor" => cursor}, scope)

    refute first.conversation_id == second.conversation_id

    assert {:error, :stale_or_invalid_cursor} =
             UserSearch.search(
               %{"query" => "page", "content" => "title", "limit" => 1, "cursor" => cursor},
               scope
             )

    assert {:ok, %{results: workspace_results}} =
             UserSearch.search(%{"query" => "page", "range" => "workspace:workspace-a"}, scope)

    assert Enum.all?(workspace_results, &(&1.workspace_id == "workspace-a"))

    assert {:ok, %{results: [%{conversation_id: "page-free"}]}} =
             UserSearch.search(%{"query" => "page", "range" => "free"}, Scope.new([], true))

    assert {:error, :invalid_input} =
             UserSearch.search(%{"query" => "page", "range" => "workspace:foreign"}, scope)

    Repo.update_all(from(c in Conversation, where: c.id == ^first.conversation_id),
      set: [status: "pending_delete"]
    )

    assert {:error, :not_accessible} = UserSearch.authorize_hit(scope, first.conversation_id)

    assert {:ok, %{incomplete: true, next_cursor: cursor}} =
             UserSearch.search(%{"query" => "missing"}, scope, max_conversations: 1)

    assert is_binary(cursor)

    {:ok, long_title} =
      ConversationStore.create("workspace-a",
        id: "long-title",
        title: String.duplicate("前", 65) <> "末尾关键字"
      )

    assert {:ok, %{results: [%{conversation_id: id, title: shown}]}} =
             UserSearch.search(
               %{"query" => "末尾关键字", "content" => "title"},
               scope,
               max_conversations: 1
             )

    assert id == long_title["id"]
    assert shown == long_title["title"]
  end

  test "title scan budgets do not reveal matches hidden by redaction", %{scope: scope} do
    {:ok, _secret} =
      ConversationStore.create("workspace-a",
        id: "redacted-title",
        title: "api_key=sk-abcdefghijklmnopqrstuvwxyz"
      )

    assert {:ok, %{results: [], incomplete: false, next_cursor: nil}} =
             UserSearch.search(
               %{"query" => "abcdefghijklmnopqrstuvwxyz", "content" => "title"},
               scope,
               max_conversations: 1
             )

    assert {:ok, %{results: [], incomplete: false, next_cursor: nil}} =
             UserSearch.search(
               %{"query" => "definitely-not-present", "content" => "title"},
               scope,
               max_conversations: 1
             )
  end

  test "entry budgets are query-independent and never exceed the requested page limit", %{
    scope: scope
  } do
    for index <- 1..3 do
      {:ok, conversation} =
        ConversationStore.create("workspace-a",
          id: "budget-#{index}",
          title: "budget title #{index}"
        )

      append(conversation["id"], %{
        "id" => "budget-message-#{index}",
        "role" => "assistant",
        "content_type" => "assistant_msg",
        "content" => "visible budget match #{index}"
      })
    end

    assert {:ok, %{results: results, incomplete: false, next_cursor: cursor}} =
             UserSearch.search(
               %{"query" => "visible budget", "content" => "assistant", "limit" => 1},
               scope,
               max_entry_candidates: 1
             )

    assert is_binary(cursor)

    assert length(results) == 1
    assert hd(results).conversation_id == "budget-3"

    {:ok, older} = ConversationStore.create("workspace-a", id: "zzz-older", title: "older")

    {:ok, newer} =
      ConversationStore.create("workspace-a", id: "aaa-newer", title: "newer activity hit")

    for index <- 1..4 do
      append(older["id"], %{
        "id" => "older-message-#{index}",
        "role" => "assistant",
        "content_type" => "assistant_msg",
        "content" => "old hit candidate #{index}"
      })
    end

    append(newer["id"], %{
      "id" => "newer-message",
      "role" => "assistant",
      "content_type" => "assistant_msg",
      "content" => "newest body hit"
    })

    Repo.update_all(from(c in Conversation, where: c.id == ^older["id"]),
      set: [updated_at: ~U[2025-01-01 00:00:00.000000Z]]
    )

    Repo.update_all(from(c in Conversation, where: c.id == ^newer["id"]),
      set: [updated_at: ~U[2030-01-01 00:00:00.000000Z]]
    )

    assert {:ok,
            %{
              results: [%{conversation_id: "aaa-newer"}],
              incomplete: false,
              next_cursor: cursor
            }} =
             UserSearch.search(
               %{"query" => "hit", "limit" => 1},
               scope,
               max_entry_candidates: 1
             )

    assert is_binary(cursor)

    {:ok, secret} = ConversationStore.create("workspace-a", id: "budget-secret", title: "secret")

    append(secret["id"], %{
      "id" => "secret-only",
      "role" => "assistant",
      "content_type" => "assistant_msg",
      "content" => "api_key=sk-abcdefghijklmnopqrstuvwxyz"
    })

    assert {:ok, secret_query} =
             UserSearch.search(
               %{"query" => "abcdefghijklmnopqrstuvwxyz"},
               scope,
               max_entry_candidates: 1
             )

    assert {:ok, absent_query} =
             UserSearch.search(
               %{"query" => "definitely-absent"},
               scope,
               max_entry_candidates: 1
             )

    assert {secret_query.results, secret_query.incomplete, is_binary(secret_query.next_cursor)} ==
             {absent_query.results, absent_query.incomplete, is_binary(absent_query.next_cursor)}
  end

  test "continuations resume inside an unconfirmed conversation without skipping older results",
       %{
         scope: scope
       } do
    {:ok, older} =
      ConversationStore.create("workspace-a", id: "continuation-older", title: "older target")

    {:ok, current} =
      ConversationStore.create("workspace-a", id: "continuation-current", title: "current")

    for index <- 1..7 do
      append(current["id"], %{
        "id" => "continuation-entry-#{index}",
        "role" => "user",
        "content_type" => "user_msg",
        "content" => if(index == 7, do: "late unique target", else: "ordinary #{index}")
      })
    end

    opts = [max_entry_candidates: 2, max_conversations: 10]
    input = %{"query" => "target", "limit" => 10}

    assert {:ok, %{results: [], incomplete: true, next_cursor: first_cursor}} =
             UserSearch.search(input, scope, opts)

    assert {:ok, %{results: [], incomplete: true, next_cursor: second_cursor}} =
             UserSearch.search(Map.put(input, "cursor", first_cursor), scope, opts)

    refute first_cursor == second_cursor

    assert {:ok, %{results: [], incomplete: true, next_cursor: third_cursor}} =
             UserSearch.search(Map.put(input, "cursor", second_cursor), scope, opts)

    assert {:ok, final_page} =
             UserSearch.search(Map.put(input, "cursor", third_cursor), scope, opts)

    assert final_page.incomplete == false
    assert final_page.next_cursor == nil

    assert Enum.map(final_page.results, & &1.conversation_id) == [
             current["id"],
             older["id"]
           ]

    assert [%{entry_id: "continuation-entry-7"}] = hd(final_page.results).matches

    assert {:error, :stale_or_invalid_cursor} =
             UserSearch.search(
               Map.merge(input, %{"cursor" => first_cursor, "content" => "user"}),
               scope,
               opts
             )
  end

  test "continuations eventually complete absent and redacted-only searches", %{scope: scope} do
    {:ok, conversation} =
      ConversationStore.create("workspace-a", id: "continuation-secret", title: "plain")

    for index <- 1..5 do
      append(conversation["id"], %{
        "id" => "continuation-secret-#{index}",
        "role" => "assistant",
        "content_type" => "assistant_msg",
        "content" => "api_key=sk-secret-continuation-#{index}"
      })
    end

    opts = [max_entry_candidates: 1]

    absent = collect_search(%{"query" => "definitely absent"}, scope, opts)
    assert absent.results == []
    assert absent.incomplete == false
    assert absent.next_cursor == nil

    redacted = collect_search(%{"query" => "secret-continuation"}, scope, opts)
    assert redacted.results == []
    assert redacted.incomplete == false
    assert redacted.next_cursor == nil
  end

  test "title continuations reach conversations beyond the bounded prefix without duplicates", %{
    scope: scope
  } do
    timestamp = ~U[2026-02-01 00:00:00.000000Z]

    for index <- 1..7 do
      id = "title-continuation-#{index}"
      title = if index == 1, do: "oldest exact title needle", else: "ordinary title #{index}"
      {:ok, _conversation} = ConversationStore.create("workspace-a", id: id, title: title)
      Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [updated_at: timestamp])
    end

    page =
      collect_search(
        %{"query" => "exact title needle", "content" => "title"},
        scope,
        max_conversations: 2
      )

    assert Enum.map(page.results, & &1.conversation_id) == ["title-continuation-1"]
    assert page.incomplete == false
    assert page.next_cursor == nil
  end

  test "a pending continuation rechecks conversation authorization and selected activity", %{
    scope: scope
  } do
    {:ok, conversation} =
      ConversationStore.create("workspace-a", id: "continuation-recheck", title: "recheck")

    for index <- 1..3 do
      append(conversation["id"], %{
        "id" => "recheck-entry-#{index}",
        "role" => "user",
        "content_type" => "user_msg",
        "content" => "ordinary"
      })
    end

    input = %{"query" => "absent"}

    assert {:ok, %{incomplete: true, next_cursor: cursor}} =
             UserSearch.search(input, scope, max_entry_candidates: 1)

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation["id"]),
      set: [status: "pending_delete"]
    )

    assert {:error, :stale_or_invalid_cursor} =
             UserSearch.search(
               Map.put(input, "cursor", cursor),
               scope,
               max_entry_candidates: 1
             )
  end

  defp collect_search(input, scope, opts, accumulated \\ [], attempts \\ 20)

  defp collect_search(_input, _scope, _opts, _accumulated, 0),
    do: flunk("search continuation did not complete")

  defp collect_search(input, scope, opts, accumulated, attempts) do
    assert {:ok, page} = UserSearch.search(input, scope, opts)
    accumulated = accumulated ++ page.results

    if page.next_cursor do
      collect_search(
        Map.put(input, "cursor", page.next_cursor),
        scope,
        opts,
        accumulated,
        attempts - 1
      )
    else
      %{page | results: accumulated}
    end
  end

  defp append(conversation_id, entry) do
    assert {:ok, _entry} = ConversationTranscriptStore.append(conversation_id, entry)
  end
end
