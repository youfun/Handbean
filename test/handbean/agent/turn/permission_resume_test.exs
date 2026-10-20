defmodule Handbean.Agent.TurnPermissionResumeTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.{Config, Message, State, Turn}

  defmodule TouchFixtureTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "permission_touch_fixture"
    def description, do: "Deterministic permission-flow fixture"
    def input_schema, do: %{type: "object", properties: %{file: %{type: "string"}}}

    def execute(%{"file" => file}, %{working_directory: workspace}) do
      :ok = File.write(Path.join(workspace, file), "approved")
      {:ok, "touched #{file}", %{file_path: file}}
    end
  end

  setup do
    :ok = Handbean.Tool.Registry.register(TouchFixtureTool, override: true)
    on_exit(fn -> Handbean.Tool.Registry.unregister(TouchFixtureTool.name()) end)
    :ok
  end

  defmodule TouchProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, _config) do
      if Enum.any?(messages, &match?(%Message{role: :tool_result}, &1)) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("done")],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      else
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([
               %{
                 type: "tool_use",
                 id: "touch_1",
                 name: "permission_touch_fixture",
                 input: %{"file" => "denied_marker"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp tmp_workspace(settings) do
    dir =
      Path.join(System.tmp_dir!(), "sigil_turn_permissions_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, ".handbean"))
    File.write!(Path.join(dir, ".handbean/settings.jsonc"), Jason.encode!(settings))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "resume_after_tool_approval/3" do
    alias Handbean.Agent.Message

    # Build an interrupted state simulating a tool_guard deny scenario.
    # This mirrors the state produced when a deny policy intercepts a tool call.
    defp build_interrupted_state do
      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        provider_config: %{}
      }

      tool_call_block = %{
        type: "tool_use",
        id: "touch_1",
        name: "bash",
        input: %{"command" => "echo hello"}
      }

      %State{
        config: config,
        messages: [
          Message.user("do something"),
          Message.tool_use([tool_call_block])
        ],
        turn: 1,
        status: :interrupted,
        error: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        tool_calls: [],
        provider_state: %{},
        response_metadata: %{},
        run_metadata: %{},
        provider_response_metadata: %{},
        interrupt_data: %{
          type: :tool_approval,
          hitl_tool_call_ids: ["touch_1"]
        },
        tool_guard_overrides: %{},
        tool_guard_denied_calls: [],
        tool_guard_result_blocks: []
      }
    end

    test "returns unchanged state for non-interrupted state with warning" do
      state = State.init(%Config{provider: TouchProvider, model: "fake", max_turns: 5}, "hello")
      assert state.status == :running

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = Turn.resume_after_tool_approval(state, [], [])
          assert result == state
        end)

      assert log =~ "resume_after_tool_approval called on non-interrupted state"
    end

    test "all-denied decisions produce denied result blocks and clear interrupt" do
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny"}]

      result =
        Turn.resume_after_tool_approval(state, decisions,
          on_event: &send(self(), {:resume_event, &1})
        )

      assert result.status == :completed
      assert result.interrupt_data == nil
      assert length(result.tool_guard_result_blocks) >= 1
      assert_receive {:resume_event, {:run_end, %{status: :completed, turns: 2, usage: usage}}}
      assert usage == result.usage
      assert_receive {:resume_event, {:agent_end, %{status: :completed}}}
      refute_receive {:resume_event, {:run_end, _}}
      refute_receive {:resume_event, {:run_start, _}}

      # Check the denied block format
      denied_block = hd(result.tool_guard_result_blocks)
      assert denied_block[:type] == "tool_result" || denied_block["type"] == "tool_result"
      assert denied_block[:is_error] == true || denied_block["is_error"] == true

      id = denied_block[:tool_use_id] || denied_block["tool_use_id"]
      assert id == "touch_1"
    end

    test "all-denied resume injects steer candidates with message_ids" do
      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(
          session_id: "turn-resume-deny-steer",
          owner: self()
        )

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer after deny",
          deliver_as: :steer,
          message_id: "msg-resume-deny-steer"
        )

      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny"}]

      result =
        Turn.resume_after_tool_approval(state, decisions,
          candidate_queue: queue,
          on_event: &send(self(), {:resume_event, &1})
        )

      assert result.status == :completed

      assert_receive {:resume_event,
                      {:candidate_message_injected,
                       %{
                         deliver_as: :steer,
                         count: 1,
                         message_ids: ["msg-resume-deny-steer"]
                       }}}
    end

    test "remember deny sets tool_guard_overrides" do
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny", "remember" => true}]

      result = Turn.resume_after_tool_approval(state, decisions, [])

      assert result.tool_guard_overrides["bash"] == :deny ||
               result.tool_guard_overrides[:bash] == :deny
    end

    test "deny plus skip on a mixed HITL batch does not hang" do
      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        provider_config: %{}
      }

      one = %{type: "tool_use", id: "a1", name: "open_url", input: %{}}
      two = %{type: "tool_use", id: "a2", name: "share_file", input: %{}}

      state = %State{
        config: config,
        messages: [Message.user("do"), Message.tool_use([one, two])],
        turn: 1,
        status: :interrupted,
        error: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        tool_calls: [],
        provider_state: %{},
        response_metadata: %{},
        run_metadata: %{},
        provider_response_metadata: %{},
        interrupt_data: %{
          type: :tool_approval,
          hitl_tool_call_ids: ["a1", "a2"]
        },
        tool_guard_overrides: %{},
        tool_guard_denied_calls: [],
        tool_guard_result_blocks: []
      }

      result =
        Turn.resume_after_tool_approval(
          state,
          [
            %{"tool_call_id" => "a1", "action" => "deny"},
            %{"tool_call_id" => "a2", "action" => "skip"}
          ],
          []
        )

      refute result.status == :interrupted

      skipped =
        Enum.find(
          result.tool_guard_result_blocks,
          &((&1[:tool_use_id] || &1["tool_use_id"]) == "a2")
        )

      assert skipped
      content = skipped[:content] || skipped["content"]
      assert content =~ "Not selected this round"
      refute content =~ "denied by user"
    end

    test "skip is distinct from a user deny" do
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "skip"}]

      result = Turn.resume_after_tool_approval(state, decisions, [])
      denied_block = hd(result.tool_guard_result_blocks)
      content = denied_block[:content] || denied_block["content"]
      details = denied_block[:details] || denied_block["details"]
      assert content =~ "Not selected this round"
      refute content =~ "denied by user"
      assert (details[:permission] || details["permission"]) in [:skipped, "skipped"]
    end

    test "denying a HITL call leaves auto-approved siblings executable" do
      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        provider_config: %{}
      }

      opened = %{type: "tool_use", id: "open_1", name: "open_url", input: %{}}
      auto = %{type: "tool_use", id: "read_1", name: "read", input: %{"file_path" => "x"}}

      state = %State{
        config: config,
        messages: [Message.user("do"), Message.tool_use([opened, auto])],
        turn: 1,
        status: :interrupted,
        error: nil,
        usage: %{input_tokens: 0, output_tokens: 0},
        tool_calls: [],
        provider_state: %{},
        response_metadata: %{},
        run_metadata: %{},
        provider_response_metadata: %{},
        interrupt_data: %{
          type: :tool_approval,
          hitl_tool_call_ids: ["open_1"],
          auto_approved_tool_call_ids: ["read_1"]
        },
        tool_guard_overrides: %{},
        tool_guard_denied_calls: [],
        tool_guard_result_blocks: []
      }

      result =
        Turn.resume_after_tool_approval(
          state,
          [%{"tool_call_id" => "open_1", "action" => "deny"}],
          []
        )

      denied = result.tool_guard_result_blocks
      assert Enum.any?(denied, &((&1[:tool_use_id] || &1["tool_use_id"]) == "open_1"))
      refute Enum.any?(denied, &((&1[:tool_use_id] || &1["tool_use_id"]) == "read_1"))
    end

    test "resume executes only explicitly permitted ids and preserves hard denials" do
      workspace = tmp_workspace(%{})

      calls = [
        %{
          type: "tool_use",
          id: "hard-denied",
          name: "permission_touch_fixture",
          input: %{"file" => "hard-denied"}
        },
        %{
          type: "tool_use",
          id: "approved",
          name: "permission_touch_fixture",
          input: %{"file" => "approved"}
        },
        %{
          type: "tool_use",
          id: "unclassified",
          name: "permission_touch_fixture",
          input: %{"file" => "unclassified"}
        }
      ]

      hard_block =
        Message.tool_result_block(
          "hard-denied",
          "Tool call denied by workspace permissions",
          true,
          %{permission: :denied, tool: "permission_touch_fixture"}
        )

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [],
        provider_config: %{}
      }

      state = %State{
        State.init(config, "do")
        | messages: [Message.user("do"), Message.tool_use(calls)],
          turn: 1,
          status: :interrupted,
          interrupt_data: %{
            type: :tool_approval,
            hitl_tool_call_ids: ["approved"],
            auto_approved_tool_call_ids: ["hard-denied"]
          },
          tool_guard_denied_calls: [hd(calls)],
          tool_guard_result_blocks: [hard_block]
      }

      result =
        Turn.resume_after_tool_approval(
          state,
          [%{"tool_call_id" => "approved", "action" => "approve"}],
          []
        )

      assert result.status == :completed
      assert File.read!(Path.join(workspace, "approved")) == "approved"
      refute File.exists?(Path.join(workspace, "hard-denied"))
      refute File.exists?(Path.join(workspace, "unclassified"))

      assert MapSet.new(Enum.map(result.tool_guard_result_blocks, & &1.tool_use_id)) ==
               MapSet.new(["hard-denied", "unclassified"])
    end

    test "empty decisions default all to deny" do
      state = build_interrupted_state()

      result = Turn.resume_after_tool_approval(state, [], [])

      assert result.status == :completed
      assert result.interrupt_data == nil
      assert length(result.tool_guard_result_blocks) >= 1
    end

    test "denied_result_block produces properly formatted block" do
      # This is a private function tested via the resume flow above,
      # but we verify the format is consistent.
      state = build_interrupted_state()
      decisions = [%{"tool_call_id" => "touch_1", "action" => "deny"}]

      result = Turn.resume_after_tool_approval(state, decisions, [])

      denied_block = hd(result.tool_guard_result_blocks)

      assert (denied_block[:type] || denied_block["type"]) == "tool_result"
      assert (denied_block[:tool_use_id] || denied_block["tool_use_id"]) == "touch_1"
      assert (denied_block[:is_error] || denied_block["is_error"]) == true

      content = denied_block[:content] || denied_block["content"]
      assert is_binary(content) and byte_size(content) > 0
    end

    test "approve executes the pending HITL tool call instead of skipping it" do
      workspace =
        tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

      marker = Path.join(workspace, "denied_marker")

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [Handbean.Agent.Middleware.ToolGuard],
        provider_config: %{}
      }

      state = State.init(config, "touch approved_marker")
      interrupted = Turn.run_loop(state, [])

      assert interrupted.status == :interrupted
      assert interrupted.interrupt_data.hitl_tool_call_ids == ["touch_1"]
      refute File.exists?(marker)

      resumed =
        Turn.resume_after_tool_approval(
          interrupted,
          [
            %{
              "tool_call_id" => "touch_1",
              "tool_name" => "permission_touch_fixture",
              "action" => "approve"
            }
          ],
          on_event: &send(self(), {:resume_event, &1})
        )

      assert resumed.status == :completed
      assert resumed.interrupt_data == nil
      assert File.exists?(marker)

      assert_receive {:resume_event, {:tool_start, %{tool_use_id: "touch_1", turn_number: 1}}}

      assert_receive {:resume_event, {:tool_end, %{tool_use_id: "touch_1", turn_number: 1}}}

      assert_receive {:resume_event,
                      {:turn_end, %{turn: 1, status: :completed, stop_reason: "tool_use_resumed"}}}

      assert_receive {:resume_event, {:run_end, %{status: :completed, usage: usage}}}
      assert usage == resumed.usage
      assert_receive {:resume_event, {:agent_end, %{status: :completed}}}
      refute_receive {:resume_event, {:run_end, _}}
      refute_receive {:resume_event, {:run_start, _}}

      tool_result =
        resumed.messages
        |> Enum.flat_map(fn
          %Message{role: role, content: blocks}
          when role in [:tool, :tool_result] and is_list(blocks) ->
            blocks

          _ ->
            []
        end)
        |> Enum.find(
          &(Map.get(&1, :tool_use_id) == "touch_1" or Map.get(&1, "tool_use_id") == "touch_1")
        )

      refute is_nil(tool_result)
      refute tool_result[:is_error] || tool_result["is_error"]
    end

    test "approve resume injects steer candidates after the HITL tool executes" do
      workspace =
        tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

      marker = Path.join(workspace, "denied_marker")

      {:ok, queue} =
        Handbean.Agent.CandidateQueue.start_link(
          session_id: "turn-resume-approve-steer",
          owner: self()
        )

      :ok =
        Handbean.Agent.CandidateQueue.enqueue(queue, "steer after approve",
          deliver_as: :steer,
          message_id: "msg-resume-approve-steer"
        )

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [Handbean.Agent.Middleware.ToolGuard],
        provider_config: %{}
      }

      interrupted = Turn.run_loop(State.init(config, "touch approved_marker"), [])
      assert interrupted.status == :interrupted

      resumed =
        Turn.resume_after_tool_approval(
          interrupted,
          [
            %{
              "tool_call_id" => "touch_1",
              "tool_name" => "permission_touch_fixture",
              "action" => "approve"
            }
          ],
          candidate_queue: queue,
          on_event: &send(self(), {:resume_event, &1})
        )

      assert resumed.status == :completed
      assert File.exists?(marker)

      assert_receive {:resume_event, {:tool_end, %{tool_use_id: "touch_1", turn_number: 1}}}

      assert_receive {:resume_event,
                      {:candidate_message_injected,
                       %{
                         deliver_as: :steer,
                         count: 1,
                         message_ids: ["msg-resume-approve-steer"]
                       }}}
    end

    test "full deny-approve flow: deny policy interrupts, then resume with deny completes" do
      workspace =
        tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

      config = %Config{
        provider: TouchProvider,
        model: "fake",
        max_turns: 5,
        working_directory: workspace,
        middleware: [Handbean.Agent.Middleware.ToolGuard],
        provider_config: %{}
      }

      state = State.init(config, "touch denied_marker")

      # First run: deny policy interrupts
      result = Turn.run_loop(state, [])

      assert result.status == :interrupted
      assert result.interrupt_data.type == :tool_approval
      assert result.interrupt_data.hitl_tool_call_ids == ["touch_1"]

      # Resume: deny the tool call
      resumed =
        Turn.resume_after_tool_approval(
          result,
          [%{"tool_call_id" => "touch_1", "action" => "deny"}],
          on_event: &send(self(), {:deny_resume_event, &1})
        )

      assert resumed.status == :completed
      assert resumed.interrupt_data == nil

      assert_receive {:deny_resume_event,
                      {:tool_end,
                       %{
                         tool_use_id: "touch_1",
                         turn_number: 1,
                         duration_ms: 0,
                         timing_fidelity: "not_started"
                       }}}

      assert_receive {:deny_resume_event,
                      {:turn_end, %{turn: 1, status: :completed, stop_reason: "tool_use_resumed"}}}

      # The denied marker file should NOT exist since we denied the touch call
      refute File.exists?(Path.join(workspace, "denied_marker"))
    end
  end

  test "deny policy returns a tool error result and does not execute the tool" do
    workspace =
      tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "deny"}}})

    config = %Config{
      provider: TouchProvider,
      model: "fake",
      max_turns: 5,
      working_directory: workspace,
      middleware: [Handbean.Agent.Middleware.ToolGuard],
      provider_config: %{}
    }

    result = Turn.run_loop(State.init(config, "touch a marker"), [])

    refute File.exists?(Path.join(workspace, "denied_marker"))
    assert result.status == :completed

    tool_result = Enum.find(result.messages, &(&1.role == :tool_result))
    assert [%{content: content, is_error: true}] = tool_result.content
    assert content =~ "Tool call denied by workspace permissions"
    refute content =~ "touch denied_marker"
  end

  test "deny policy injects steer candidates after blocked tools" do
    workspace =
      tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "deny"}}})

    {:ok, queue} =
      Handbean.Agent.CandidateQueue.start_link(session_id: "turn-deny-inject", owner: self())

    defmodule EnqueueSteerAfterToolRequest do
      @behaviour Handbean.Agent.Middleware

      def call(:after_tool_request, state) do
        queue = state.config.context[:queue]

        :ok =
          Handbean.Agent.CandidateQueue.enqueue(queue, "steer after deny-block",
            deliver_as: :steer,
            message_id: "msg-deny-block-steer"
          )

        state
      end

      def call(_hook, state), do: state
    end

    {:ok, events} = Agent.start_link(fn -> [] end)

    config = %Config{
      provider: TouchProvider,
      model: "fake",
      max_turns: 5,
      working_directory: workspace,
      middleware: [EnqueueSteerAfterToolRequest, Handbean.Agent.Middleware.ToolGuard],
      context: %{queue: queue},
      provider_config: %{}
    }

    result =
      Turn.run_loop(State.init(config, "touch a marker"),
        candidate_queue: queue,
        on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
      )

    assert result.status == :completed

    injected =
      events
      |> Agent.get(& &1)
      |> Enum.filter(&match?({:candidate_message_injected, _}, &1))

    assert [
             {:candidate_message_injected,
              %{deliver_as: :steer, count: 1, message_ids: ["msg-deny-block-steer"]}}
             | _
           ] = injected
  end

  test "prompt policy interrupts before tool execution and emits approval request" do
    workspace =
      tmp_workspace(%{"tools" => %{"per_tool" => %{"permission_touch_fixture" => "prompt"}}})

    events = Agent.start_link(fn -> [] end) |> elem(1)

    config = %Config{
      provider: TouchProvider,
      model: "fake",
      max_turns: 5,
      working_directory: workspace,
      middleware: [Handbean.Agent.Middleware.ToolGuard],
      provider_config: %{}
    }

    result =
      Turn.run_loop(State.init(config, "touch a marker"),
        on_event: fn event -> Agent.update(events, &(&1 ++ [event])) end
      )

    refute File.exists?(Path.join(workspace, "denied_marker"))
    assert result.status == :interrupted
    assert result.interrupt_data.type == :tool_approval
    assert result.interrupt_data.hitl_tool_call_ids == ["touch_1"]

    assert Enum.any?(Agent.get(events, & &1), fn
             {:tool_approval_requested, %{hitl_tool_call_ids: ["touch_1"]}} -> true
             _ -> false
           end)
  end
end
