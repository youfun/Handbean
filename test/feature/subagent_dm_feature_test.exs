defmodule HandbeanWeb.Feature.SubagentDmFeatureTest do
  @moduledoc """
  PhoenixTest feature test for direct messages to a subagent from the
  workspace composer: `@<subagent_type or child id> text` is routed to the
  subagent instead of the parent conversation; anything else stays a normal
  message.

  Run: mix test test/feature/subagent_dm_feature_test.exs
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.Agent.{Coordinator, Delegation, Message}
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  setup do
    context = E2EHarness.isolate_home!("subagent-dm-feature")
    E2EHarness.use_fake_provider!(:simple_answer)

    on_exit(fn ->
      for conversation <-
            ConversationStore.list(include_timeline?: false, include_internal?: true) do
        E2EHarness.cancel!(conversation["id"])
      end
    end)

    context
  end

  # Parent delegates once, then answers once the report arrives; the child
  # answers with the last user line it sees.
  defp script do
    fn messages, defs ->
      text = messages |> Enum.map_join("\n", &Message.text/1)
      child? = "task" not in Enum.map(defs, & &1.name)

      cond do
        child? ->
          "child says: " <> (text |> String.split("\n") |> List.last())

        text =~ "Background subagent report" ->
          "parent saw report"

        Enum.count(messages, &match?(%Message{role: :tool_result}, &1)) == 0 ->
          {:tools, [%{name: "task", input: %{"task" => "investigate", "criteria" => "one line"}}]}

        true ->
          "dispatched"
      end
    end
  end

  defp start_parent(sid, workspace) do
    {:ok, _} =
      Coordinator.add_message(sid, "delegate the work",
        workspace_path: workspace,
        model: "fake/fake-model",
        provider: Handbean.TestSupport.FakeProvider,
        provider_config: %{scenario: {:script, script()}},
        tools: Handbean.Agent.default_tools(),
        source: :cli,
        streaming: false
      )

    receive do
      {:agent_event, %{kind: :subagent_end, payload: %{status: :completed} = payload}} -> payload
    after
      15_000 -> flunk("subagent never finished")
    end
  end

  defp await_parent_report(sid) do
    receive do
      {:agent_event, %{kind: :run_end, payload: %{status: status}}} when status != :interrupted ->
        texts =
          for %{"role" => "assistant", "content" => content} <- transcript(sid), do: content

        if Enum.any?(texts, &String.contains?(&1, "parent saw report")),
          do: :ok,
          else: await_parent_report(sid)
    after
      15_000 -> flunk("parent never saw the report: #{inspect(transcript(sid))}")
    end
  end

  defp transcript(id) do
    {:ok, entries} = ConversationStore.load_messages_result(id)
    entries
  end

  # Drains Delegation and runners so nothing writes under the temp HOME after
  # on_exit restores it.
  defp settle(ids, attempts \\ 200) do
    state = :sys.get_state(Delegation)

    busy? =
      state.jobs != %{} or state.reports != %{} or
        Enum.any?(ids, &(Registry.lookup(Handbean.AgentRunRegistry, &1) != []))

    if busy? and attempts > 0 do
      receive after: (20 -> settle(ids, attempts - 1))
    else
      :ok
    end
  end

  test "@subagent text in the composer goes to the subagent, not the parent", %{
    conn: conn,
    workspace: workspace
  } do
    sid = "dm-feature-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    on_exit(fn -> E2EHarness.cancel!(sid) end)
    :ok = Session.subscribe(sid)

    child = start_parent(sid, workspace).child_conversation_id
    on_exit(fn -> E2EHarness.cancel!(child) end)
    assert {:ok, %{"workspace_id" => "default"}} = ConversationStore.get_metadata(child)
    await_parent_report(sid)

    conn
    |> visit("/w/default/c/#{sid}")
    |> fill_in("#ai-input", "Message", with: "@researcher what did you find?", exact: false)
    |> click_button("#send-button", "")
    |> assert_has("textarea#ai-input", "")
    |> assert_has("#flash-group", "follow-up")

    child_entries = transcript(child)

    assert Enum.any?(
             child_entries,
             &(&1["role"] == "user" and &1["content"] == "what did you find?")
           )

    refute Enum.any?(
             transcript(sid),
             &(&1["role"] == "user" and &1["content"] =~ "what did you find?")
           )

    # Let the follow-up run finish so nothing writes under the temp HOME after
    # on_exit restores it.
    receive do
      {:agent_event, %{kind: :subagent_end, payload: %{kind: :dm, status: :completed}}} -> :ok
    after
      15_000 -> flunk("subagent follow-up never finished")
    end

    assert Enum.any?(
             transcript(child),
             &(&1["role"] == "assistant" and &1["content"] =~ "what did you find?")
           )

    settle([sid, child])
  end

  test "@name with no matching subagent stays a normal message", %{conn: conn} do
    conn
    |> visit("/")
    |> fill_in("#ai-input", "Message", with: "@nobody hi there", exact: false)
    |> click_button("#send-button", "")
    |> assert_has(".msg-bubble.msg-user", "@nobody hi there")
    |> refute_has("#flash-group", "subagent")
  end
end
