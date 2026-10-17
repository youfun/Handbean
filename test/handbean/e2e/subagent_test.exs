defmodule Handbean.E2E.SubagentTest do
  @moduledoc """
  Parent run → `task` → Delegation → child Runner → report → parent follow-up,
  plus direct messages to a child and cascade cancellation.

  Run: mix test --include e2e test/handbean/e2e/subagent_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.{Coordinator, Delegation, Message}
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session

  @moduletag :e2e
  @report_marker "Background subagent report for child_conversation_id"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "subagent-e2e-#{Ecto.UUID.generate()}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)

    old_home = System.get_env("HOME")
    old_models = System.get_env("HANDBEAN_MODELS_FILE")
    models = Path.join(root, "models.json")

    File.write!(
      models,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HOME", home)
    System.put_env("HANDBEAN_MODELS_FILE", models)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if old_models,
        do: System.put_env("HANDBEAN_MODELS_FILE", old_models),
        else: System.delete_env("HANDBEAN_MODELS_FILE")

      File.rm_rf!(root)
    end)

    sid = "subagent-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    %{sid: sid, workspace: workspace, home: home, old_home: old_home}
  end

  defp start(sid, workspace, fun) do
    {:ok, _} =
      Coordinator.add_message(sid, "delegate the work",
        workspace_path: workspace,
        model: "fake/fake-model",
        provider: Handbean.TestSupport.FakeProvider,
        provider_config: %{scenario: {:script, fun}},
        tools: Handbean.Agent.default_tools(),
        source: :cli,
        streaming: false,
        max_turns: 6
      )
  end

  defp child?(defs), do: "task" not in Enum.map(defs, & &1.name)
  defp all_text(messages), do: Enum.map_join(messages, "\n", &Message.text/1)
  defp tool_results(messages), do: Enum.count(messages, &match?(%Message{role: :tool_result}, &1))

  defp task_call(task, extra \\ %{}) do
    %{
      name: "task",
      input: Map.merge(%{"task" => task, "criteria" => "answer in one line"}, extra)
    }
  end

  defp await_event(kind, match) do
    receive do
      {:agent_event, %{kind: ^kind, payload: payload}} ->
        if match.(payload), do: payload, else: await_event(kind, match)
    after
      15_000 -> flunk("no #{kind} event")
    end
  end

  defp entries(id) do
    {:ok, entries} = ConversationStore.load_messages_result(id)
    entries
  end

  defp assistant_texts(id) do
    for %{"role" => "assistant", "content" => content} <- entries(id), do: content
  end

  defp await_assistant(sid, text, attempts \\ 20) do
    cond do
      Enum.any?(assistant_texts(sid), &(&1 == text)) ->
        :ok

      attempts == 0 ->
        flunk("parent never answered #{inspect(text)}: #{inspect(assistant_texts(sid))}")

      true ->
        receive do
          {:agent_event, %{kind: :run_end}} -> :ok
        after
          15_000 ->
            flunk(
              "parent never answered #{inspect(text)}; transcript: " <>
                inspect(Enum.map(entries(sid), &Map.take(&1, ["role", "content", "tool_name"]))) <>
                "\nsubagents: " <> inspect(Delegation.status(sid, :list))
            )
        end

        await_assistant(sid, text, attempts - 1)
    end
  end

  # Drains Delegation, runners, and completion tasks so nothing writes under
  # HOME after on_exit restores it.
  defp settle(ids, attempts \\ 200) do
    state = :sys.get_state(Delegation)

    busy? =
      state.jobs != %{} or state.reports != %{} or
        Enum.any?(ids, &(Registry.lookup(Handbean.AgentRunRegistry, &1) != []))

    cond do
      busy? and attempts > 0 ->
        receive after: (20 -> settle(ids, attempts - 1))

      busy? ->
        flunk("delegation did not settle: #{inspect(Map.take(state, [:jobs, :reports]))}")

      true ->
        for pid <- Task.Supervisor.children(Handbean.AgentRunTaskSupervisor) do
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        end

        for id <- ids do
          {:ok, session} = Session.start_or_get(session_id: id)
          :sys.get_state(session)
        end

        if tracker = Process.whereis(Handbean.Runtime.TaskTracker), do: :sys.get_state(tracker)
        :ok
    end
  end

  defp children(sid) do
    {:ok, list} = Delegation.status(sid, :list)
    list
  end

  test "parallel background subagents report back and wake the parent", %{
    sid: sid,
    workspace: workspace
  } do
    File.mkdir_p!(Path.join(workspace, ".handbean/agents"))

    File.write!(Path.join(workspace, ".handbean/agents/summarizer.md"), """
    ---
    name: summarizer
    description: summarizes one file
    tools: [read, write, task]
    ---
    Summarize. Never write.
    """)

    test_pid = self()

    fun = fn messages, defs ->
      text = all_text(messages)

      cond do
        child?(defs) ->
          send(test_pid, {:child_defs, Enum.map(defs, & &1.name)})
          "child says: " <> (text |> String.split("\n") |> hd())

        length(String.split(text, @report_marker)) - 1 >= 2 ->
          "got both reports"

        text =~ @report_marker ->
          "got one report"

        tool_results(messages) == 0 ->
          {:tools, [task_call("alpha"), task_call("beta", %{"subagent_type" => "summarizer"})]}

        true ->
          "dispatched"
      end
    end

    start(sid, workspace, fun)
    await_assistant(sid, "got both reports")

    [%{child_conversation_id: a}, %{child_conversation_id: b}] = kids = children(sid)
    settle([sid, a, b])

    assert Enum.map(kids, & &1.subagent_type) |> Enum.sort() == ["researcher", "summarizer"]
    assert Enum.all?(kids, &(&1.status == :completed))

    for _ <- 1..2 do
      assert_received {:child_defs, names}
      refute Enum.any?(names, &(&1 in ~w(task task_status advisor write edit bash)))
    end

    parent = entries(sid)

    task_entries = Enum.filter(parent, &(&1["tool_name"] == "task"))
    assert length(task_entries) == 2
    assert Enum.all?(task_entries, &(&1["tool_status"] == "done"))

    reports =
      parent
      |> Enum.filter(&(&1["role"] == "user" and &1["content"] =~ @report_marker))
      |> Enum.map_join("\n", & &1["content"])

    assert reports =~ a and reports =~ b
    assert reports =~ "child says: alpha" and reports =~ "child says: beta"

    assert [sid] == Enum.map(ConversationStore.list(), & &1["id"])
    assert ConversationStore.internal?(a) and ConversationStore.internal?(b)
    assert map_size(ConversationStore.delegated_usage(sid)) == 2
  end

  test "direct messages steer a running subagent and follow up after it finishes", %{
    sid: sid,
    workspace: workspace
  } do
    File.write!(Path.join(workspace, "notes.txt"), "notes")
    test_pid = self()

    fun = fn messages, defs ->
      text = all_text(messages)

      cond do
        child?(defs) and text =~ "one more question" ->
          send(test_pid, {:follow_up_context, Enum.map(defs, & &1.name), text})
          "follow-up answer; remembered=#{text =~ "steered answer"}"

        child?(defs) and tool_results(messages) == 0 ->
          send(test_pid, {:child_blocked, self()})

          receive do
            :go -> {:tools, [%{name: "read", input: %{"file_path" => "notes.txt"}}]}
          end

        child?(defs) ->
          if text =~ "focus on notes", do: "steered answer", else: "unsteered answer"

        text =~ @report_marker ->
          "parent saw report"

        tool_results(messages) == 0 ->
          {:tools, [task_call("investigate")]}

        true ->
          "dispatched"
      end
    end

    start(sid, workspace, fun)
    assert_receive {:child_blocked, child_task}, 10_000

    assert {:ok, %{delivery: :steer, child_conversation_id: child}} =
             Delegation.message(sid, "researcher", "focus on notes")

    send(child_task, :go)
    await_assistant(sid, "parent saw report")
    settle([sid, child])

    assert {:ok, %{delivery: :follow_up}} =
             Delegation.message(sid, child, "one more question")

    assert_receive {:follow_up_context, tools, follow_up_context}, 10_000
    assert "read" in tools
    assert follow_up_context =~ "focus on notes"
    assert follow_up_context =~ "steered answer"
    assert follow_up_context =~ "one more question"

    ended =
      await_event(:subagent_end, &(&1.child_conversation_id == child and &1.kind == :dm))

    assert ended.status == :completed
    assert ended.report == "follow-up answer; remembered=true"
    settle([sid, child])

    reports =
      Enum.filter(entries(sid), &(&1["role"] == "user" and &1["content"] =~ @report_marker))

    assert length(reports) == 1, "a DM reply is not forwarded to the parent by default"

    assert map_size(ConversationStore.delegated_usage(sid)) == 2
    assert {:error, _} = Delegation.message("another-conversation", child, "hijack")
  end

  test "cancelling the parent run cancels its background subagents", %{
    sid: sid,
    workspace: workspace
  } do
    test_pid = self()

    fun = fn messages, defs ->
      cond do
        child?(defs) ->
          send(test_pid, :child_started)
          receive do: (:never -> "unreachable")

        tool_results(messages) == 0 ->
          {:tools, [task_call("wait forever")]}

        true ->
          send(test_pid, :parent_waiting)
          receive do: (:never -> "unreachable")
      end
    end

    start(sid, workspace, fun)
    assert_receive :child_started, 10_000
    assert_receive :parent_waiting, 10_000
    [%{child_conversation_id: child}] = children(sid)

    assert :ok = Coordinator.cancel(sid)
    ended = await_event(:subagent_end, &(&1.child_conversation_id == child))
    assert ended.status == :parent_closed
    settle([sid, child])

    assert Registry.lookup(Handbean.AgentRunRegistry, child) == []
    assert [%{status: :parent_closed}] = children(sid)

    refute Enum.any?(entries(sid), &(&1["role"] == "user" and &1["content"] =~ @report_marker))
  end

  test "a write subagent works in a worktree and its diff lands only on apply", %{
    sid: sid,
    workspace: workspace,
    home: home,
    old_home: old_home
  } do
    git = fn args ->
      {_, 0} = System.cmd("git", args, cd: workspace, env: [{"HOME", old_home}])
    end

    git.(["init", "-q"])
    File.write!(Path.join(workspace, "README.md"), "base\n")
    git.(["add", "README.md"])
    git.(["commit", "-q", "-m", "base"])

    File.mkdir_p!(Path.join(home, ".handbean/agents"))

    File.write!(Path.join(home, ".handbean/agents/writer.md"), """
    ---
    name: writer
    description: writes files
    tools: [write, read]
    mode: write
    isolation: worktree
    ---
    Write what you are asked to.
    """)

    fun = fn messages, defs ->
      cond do
        child?(defs) and tool_results(messages) == 0 ->
          {:tools, [%{name: "write", input: %{"file_path" => "new.txt", "content" => "child\n"}}]}

        child?(defs) ->
          "wrote new.txt"

        all_text(messages) =~ @report_marker ->
          "parent saw diff"

        tool_results(messages) == 0 ->
          {:tools, [task_call("write new.txt", %{"subagent_type" => "writer"})]}

        true ->
          "dispatched"
      end
    end

    start(sid, workspace, fun)
    await_assistant(sid, "parent saw diff")
    [%{child_conversation_id: child, worktree: worktree}] = children(sid)
    settle([sid, child])

    assert {:ok, %{diff_stat: stat, status: :completed}} = Delegation.status(sid, :get, child)
    assert stat =~ "new.txt"
    refute File.exists?(Path.join(workspace, "new.txt"))
    assert File.read!(Path.join(worktree, "new.txt")) == "child\n"

    report = Enum.find(entries(sid), &(&1["role"] == "user" and &1["content"] =~ @report_marker))
    assert report["content"] =~ "new.txt"

    assert {:ok, applied} = Delegation.worktree(sid, :apply, child)
    assert applied =~ "new.txt"
    assert File.read!(Path.join(workspace, "new.txt")) == "child\n"
    refute File.exists?(worktree)
    assert {:error, _} = Delegation.worktree(sid, :discard, child)

    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: workspace)
    refute status =~ ".handbean/worktrees"
  end
end
