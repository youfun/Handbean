defmodule Handbean.Permissions.AutoReviewLedgerTest do
  use Handbean.Permissions.AutoReviewTestSupport

  test "three consecutive denies halt the turn" do
    dir =
      workspace(%{
        "tools" => %{
          "approvals_reviewer" => "auto_review",
          "per_tool" => %{"auto_review_marker" => "prompt"}
        }
      })

    {:ok, reviews} = Agent.start_link(fn -> 0 end)

    Process.put(AutoReview.transport_key(), fn request ->
      Agent.update(reviews, &(&1 + 1))

      {:ok,
       Jason.encode!(%{
         "decisions" =>
           Enum.map(request.action_requests, fn req ->
             %{
               "tool_call_id" => req.tool_call_id,
               "decision" => "deny",
               "rationale" => "still no"
             }
           end)
       })}
    end)

    defmodule RepeatProvider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tools, _config) do
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([
               %{
                 type: "tool_use",
                 id: "d#{System.unique_integer([:positive])}",
                 name: "auto_review_marker",
                 input: %{"file" => "should-not-run"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
    end

    config = %Config{
      provider: RepeatProvider,
      model: "fake",
      max_turns: 8,
      working_directory: dir,
      middleware: [ToolGuard],
      provider_config: %{}
    }

    {:ok, event_log} = Agent.start_link(fn -> [] end)

    result =
      Turn.run_loop(State.init(config, "keep trying"),
        on_event: fn event -> Agent.update(event_log, &[event | &1]) end
      )

    assert result.status == :halted

    assert {:run_end, %{status: :halted}} =
             event_log
             |> Agent.get(& &1)
             |> Enum.reverse()
             |> Enum.find(fn
               {:run_end, _} -> true
               _ -> false
             end)

    assert result.error =~ "超时不会被当成拒绝"
    assert Agent.get(reviews, & &1) == 3
    refute File.exists?(Path.join(dir, "should-not-run"))

    denied =
      result.messages
      |> Enum.filter(&(&1.role == :tool_result))
      |> Enum.flat_map(& &1.content)

    assert length(denied) == 3
    assert Enum.all?(denied, &(&1.content =~ AutoReview.no_workaround()))
  end

  test "a halt does not execute an approved sibling in the same batch" do
    dir =
      workspace(%{
        "tools" => %{
          "approvals_reviewer" => "auto_review",
          "per_tool" => %{"auto_review_marker" => "prompt"}
        }
      })

    Process.put(:halt_batch_step, 0)

    Process.put(AutoReview.transport_key(), fn request ->
      {:ok,
       Jason.encode!(%{
         "decisions" =>
           Enum.map(request.action_requests, fn req ->
             decision =
               if req.tool_name == "auto_review_marker" and req.tool_call_id == "ok",
                 do: "approve",
                 else: "deny"

             %{
               "tool_call_id" => req.tool_call_id,
               "decision" => decision,
               "rationale" => decision
             }
           end)
       })}
    end)

    defmodule HaltBatchProvider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tools, _config) do
        step = Process.get(:halt_batch_step, 0)
        Process.put(:halt_batch_step, step + 1)

        calls =
          case step do
            0 ->
              [
                %{
                  type: "tool_use",
                  id: "d1",
                  name: "auto_review_marker",
                  input: %{"file" => "no-1"}
                }
              ]

            1 ->
              [
                %{
                  type: "tool_use",
                  id: "d2",
                  name: "auto_review_marker",
                  input: %{"file" => "no-2"}
                }
              ]

            _ ->
              [
                %{
                  type: "tool_use",
                  id: "d3",
                  name: "auto_review_marker",
                  input: %{"file" => "no-3"}
                },
                %{
                  type: "tool_use",
                  id: "ok",
                  name: "auto_review_marker",
                  input: %{"file" => "approved-sibling"}
                }
              ]
          end

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [Message.tool_use(calls)],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
    end

    config = %Config{
      provider: HaltBatchProvider,
      model: "fake",
      max_turns: 8,
      working_directory: dir,
      middleware: [ToolGuard],
      provider_config: %{}
    }

    result = Turn.run_loop(State.init(config, "keep trying"), [])

    assert result.status == :halted
    refute File.exists?(Path.join(dir, "approved-sibling"))
    refute File.exists?(Path.join(dir, "no-3"))
  end

  test "a non-deny resets the consecutive counter and ten denies in the window stop" do
    ledger =
      AutoReview.record(AutoReview.initial_ledger(), [
        %{decision: :deny},
        %{decision: :deny},
        %{decision: :approve}
      ])

    refute ledger.stop
    assert ledger.consecutive_denies == 0

    mixed =
      Enum.flat_map(1..5, fn _ ->
        [%{decision: :deny}, %{decision: :deny}, %{decision: :approve}]
      end)

    stopped = AutoReview.record(AutoReview.initial_ledger(), mixed)
    assert stopped.stop
    assert Enum.count(stopped.recent, &(&1 == :deny)) == 10
  end
end
