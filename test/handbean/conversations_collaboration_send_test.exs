defmodule Handbean.ConversationsCollaborationSendTest do
  use Handbean.ConversationsCase, async: false

  alias Handbean.{ConversationStore, ConversationTranscriptStore}
  alias Handbean.Conversations.Collaboration

  test "cross-workspace send rejects before persistence; same-workspace send needs no opt-in",
       c do
    input = %{"conversation" => c.foreign, "message" => "x", "request_id" => "x"}
    assert {:error, :not_accessible} = Collaboration.send_message(input, c.context)
    assert {:ok, []} = ConversationTranscriptStore.list(c.source)

    assert {:ok, _} = Collaboration.send_message(%{input | "conversation" => c.target}, c.context)
  end

  test "concurrent identical sends reserve only once; uncertain delivery is not retried", c do
    input = %{"conversation" => c.target, "message" => "Report", "request_id" => "request"}

    results =
      1..8
      |> Task.async_stream(fn _ -> Collaboration.send_message(input, c.context) end)
      |> Enum.to_list()

    assert Enum.all?(results, fn {:ok, {:ok, receipt}} ->
             receipt.delivery == "delivery_unknown"
           end)

    {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert length(entries) == 1
    assert hd(entries)["content"] == "Report"

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(%{input | "message" => "Changed"}, c.context)

    assert {:ok, []} = ConversationTranscriptStore.list(c.target)
  end

  test "a root conversation creates any number of read-only children", c do
    input = %{"title" => "Audit", "message" => "Inspect", "request_id" => "child"}
    refute Collaboration.create(input, c.context) == {:error, :delegation_not_permitted}
    {:ok, receipt} = Collaboration.create(input, c.context)
    {:ok, same} = Collaboration.create(input, c.context)
    assert same.conversation == receipt.conversation
    child_context = %{c.context | conversation_id: receipt.conversation}

    for name <-
          ~w(read grep file_search code_search web_fetch mem_recall skill tool_search send_conversation_message) do
      assert Collaboration.tool_allowed?(name, child_context)
    end

    for name <- ~w(write edit bash browser task create_conversation mem_learn) do
      refute Collaboration.tool_allowed?(name, child_context)
    end

    ConversationStore.upsert(%{
      "id" => receipt.conversation,
      "workspace_id" => "ws",
      "title" => "UI save",
      "timeline" => []
    })

    refute Collaboration.tool_allowed?("write", child_context)

    assert {:error, :invalid_input} =
             Collaboration.reply(
               %{"conversation" => c.foreign, "message" => "x", "request_id" => "reply"},
               child_context
             )

    assert {:ok, %{conversation: parent}} =
             Collaboration.reply(%{"message" => "Result", "request_id" => "reply"}, child_context)

    assert parent == c.source
    assert {:error, :delegation_not_permitted} = Collaboration.create(input, child_context)

    {:ok, sibling} = Collaboration.create(%{input | "request_id" => "sibling"}, c.context)

    assert {:ok, _} =
             Collaboration.send_message(
               %{
                 "conversation" => sibling.conversation,
                 "message" => "from sibling",
                 "request_id" => "sib-msg"
               },
               child_context
             )

    for i <- 3..6 do
      assert {:ok, _} = Collaboration.create(%{input | "request_id" => "child#{i}"}, c.context)
    end
  end

  test "handoffs are not capped by count", c do
    for i <- 1..12 do
      assert {:ok, _} =
               Collaboration.send_message(
                 %{"conversation" => c.target, "message" => "x", "request_id" => "#{i}"},
                 c.context
               )
    end

    {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert Enum.count(entries, &(&1["content_type"] == "conversation_handoff")) == 12
  end

  test "registered tools use executor-owned context and deny writes in delegated runs", c do
    modules = Handbean.Tool.Registry.host_tool_modules()
    names = Enum.map(modules, & &1.name())

    for name <-
          ~w(list_conversations find_conversation read_conversation get_conversation_status get_conversation_trajectory send_conversation_message reply_to_parent_conversation create_conversation),
        do: assert(name in names)

    Enum.each(modules, &Handbean.Tool.Registry.register/1)

    declared = Handbean.Tool.Registry.tool_defs() |> Enum.map(& &1.name)
    refute "get_conversation_trajectory" in declared

    config =
      Handbean.Agent.Config.from_opts(
        conversation_id: c.source,
        workspace_id: "ws",
        working_directory: c.home,
        context: %{conversation_run_opts: [forged: true]}
      )

    state = Handbean.Agent.State.init(config, "test")

    assert {:ok, _, [block]} =
             Handbean.Agent.Tool.Executor.execute_all_with_details(
               [%{id: "list", name: "list_conversations", input: %{}}],
               state
             )

    refute block.is_error
    assert Jason.decode!(block.content)["conversations"] |> length() == 2
    ConversationStore.update_meta(c.source, collaboration: %{"read_only" => true})
    authorized = Handbean.Agent.Tool.Executor.authorized_tools(config)
    assert "web_fetch" in authorized
    assert "grep" in authorized
    assert "mem_recall" in authorized
    refute "write" in authorized
    refute "bash" in authorized
    refute "task" in authorized
    path = Path.join(c.home, "must-not-exist")

    assert {:ok, _, [denied]} =
             Handbean.Agent.Tool.Executor.execute_all_with_details(
               [%{id: "write", name: "write", input: %{"file_path" => path, "content" => "bad"}}],
               state
             )

    assert denied.is_error
    refute File.exists?(path)
  end
end
