defmodule Handbean.Agent.TranscriptPersistence.TerminalTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.TranscriptPersistence

  setup do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_agent_transcript_home_#{System.unique_integer([:positive])}"
      )

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "marks unfinished tools as error on run_end with error" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    # Start a tool but never send tool_end (simulating a crash)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "toolu_crash", tool: "bash", input: %{command: "bad"}}}
    )

    # run_end with error (simulating crash before tool_end)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: "error", error: "nxdomain"}}
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)
    tool = Enum.find(messages, &(&1["id"] == "tool-toolu_crash"))

    assert tool, "expected the tool entry in the transcript"

    assert tool["tool_status"] == "error",
           "expected tool_status to be error, got: #{inspect(tool["tool_status"])}"
  end

  test "run_end cancelled scans durable running tools without process-local tracking" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    run_id = "run-cancel-#{System.unique_integer([:positive])}"
    opts = [run_id: run_id]

    task =
      Task.async(fn ->
        TranscriptPersistence.handle_event(
          conversation_id,
          {:run_start, %{model: "test"}},
          opts
        )

        TranscriptPersistence.handle_event(
          conversation_id,
          {:tool_start,
           %{tool_use_id: "toolu_hold", tool: "bash", input: %{command: "sleep 30"}}},
          opts
        )
      end)

    Task.await(task)

    refute Process.get({Handbean.Agent.TranscriptPersistence, :running_tools, conversation_id})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: "cancelled", turns: 0}},
      opts
    )

    tool =
      Enum.find(
        Handbean.ConversationStore.load_messages(conversation_id),
        &(&1["id"] == "tool-toolu_hold")
      )

    assert tool["tool_status"] == "cancelled"
  end

  test "run_end cancelled only patches the same run and keeps terminal tool statuses" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts_a = [run_id: "run-a"]
    opts_b = [run_id: "run-b"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts_a)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-running", tool: "bash", input: %{command: "hold"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-done", tool: "read", input: %{path: "a.txt"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-done", tool: "read", output: "ok"}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-error", tool: "bash", input: %{command: "bad"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-error", tool: "bash", error: "failed"}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-cancelled", tool: "bash", input: %{command: "x"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-cancelled", tool: "bash", status: :cancelled}},
      opts_a
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts_b)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "b-running", tool: "bash", input: %{command: "other"}}},
      opts_b
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: :cancelled, turns: 0}},
      opts_a
    )

    messages = Handbean.ConversationStore.load_messages(conversation_id)
    by_id = Map.new(messages, &{&1["id"], &1})

    assert by_id["tool-a-running"]["tool_status"] == "cancelled"
    assert by_id["tool-a-done"]["tool_status"] == "done"
    assert by_id["tool-a-error"]["tool_status"] == "error"
    assert by_id["tool-a-cancelled"]["tool_status"] == "cancelled"
    assert by_id["tool-b-running"]["tool_status"] == "running"
  end

  test "run_end interrupted does not cancel running tools" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "run-interrupt"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "approval-running", tool: "bash", input: %{command: "pwd"}}},
      opts
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: :interrupted}}, opts)

    tool =
      Enum.find(
        Handbean.ConversationStore.load_messages(conversation_id),
        &(&1["id"] == "tool-approval-running")
      )

    assert tool["tool_status"] == "running"

    assert {:ok, %{input_tokens: 0, output_tokens: 0}} =
             Handbean.ConversationStore.get_token_usage(conversation_id)
  end

  test "terminal run_end records usage once and interrupted does not" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "run-usage"]

    usage = %{
      input_tokens: 9,
      output_tokens: 2,
      cache_read_input_tokens: 5,
      cache_creation_input_tokens: 3,
      total_input_tokens: 14
    }

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :interrupted, usage: %{input_tokens: 4, output_tokens: 1}}},
               opts
             )

    assert {:ok, %{input_tokens: 0}} = Handbean.ConversationStore.get_token_usage(conversation_id)

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :completed, usage: usage}},
               opts
             )

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :completed, usage: usage}},
               opts
             )

    assert {:ok,
            %{
              input_tokens: 9,
              output_tokens: 2,
              cache_read_tokens: 5,
              cache_write_tokens: 3,
              total_input_tokens: 14,
              usage_incomplete: false
            }} = Handbean.ConversationStore.get_token_usage(conversation_id)
  end

  test "terminal stop notices are written once" do
    {:ok, conversation} = Handbean.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "run-stop"]

    for status <- [:max_turns, :stalled, :budget_exceeded, :halted] do
      assert :ok =
               TranscriptPersistence.handle_event(
                 conversation_id,
                 {:run_end, %{status: status, turns: 4, evidence: "same grep"}},
                 opts
               )
    end

    assert :ok =
             TranscriptPersistence.handle_event(
               conversation_id,
               {:run_end, %{status: :max_turns, turns: 4}},
               opts
             )

    stops =
      conversation_id
      |> Handbean.ConversationStore.load_messages()
      |> Enum.filter(&(&1["id"] == "msg-run-stop-run-stop"))

    assert [%{"content" => content}] = stops
    assert content =~ "轮上限"
  end
end
