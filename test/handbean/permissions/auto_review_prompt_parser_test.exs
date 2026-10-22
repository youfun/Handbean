defmodule Handbean.Permissions.AutoReviewPromptParserTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Message
  alias Handbean.Permissions.AutoReview

  test "review prompt tells the reviewer when the host has no OS sandbox" do
    prompt = AutoReview.build_prompt([], [], File.cwd!())

    if Handbean.Platform.ProcessSandbox.os_enforced?() do
      refute prompt =~ "Host sandbox: none"
    else
      assert prompt =~ "Host sandbox: none"
      assert prompt =~ "Do not deny solely"

      assert AutoReview.policy_text() =~
               "Do not deny solely because that host cannot confine bash"
    end
  end

  test "ambiguous batch output fails closed" do
    requests = [%{tool_call_id: "a"}, %{tool_call_id: "b"}]

    assert {:error, :unattributable} =
             AutoReview.parse_decisions(~s({"decision":"approve","rationale":"ok"}), requests)

    assert {:ok, [%{tool_call_id: "only", decision: :approve}]} =
             AutoReview.parse_decisions(~s({"decision":"approve","rationale":"ok"}), [
               %{tool_call_id: "only"}
             ])

    assert {:ok, [%{tool_call_id: "only", decision: :needs_human}]} =
             AutoReview.parse_decisions(
               ~s({"decision":"needs_human","rationale":"requires a choice"}),
               [%{tool_call_id: "only"}]
             )
  end

  test "review prompt omits hidden reasoning and says the batch is out of bounds" do
    messages = [
      Message.user("please run the local check"),
      Message.assistant_blocks([
        %{type: "thinking", thinking: "SECRET_REASONING_abc"},
        %{type: "responses_reasoning", summary: "HIDDEN_SUMMARY_xyz"},
        %{type: "tool_use", id: "t1", name: "bash", input: %{"command" => "mix test"}}
      ])
    ]

    prompt =
      AutoReview.build_prompt(
        messages,
        [%{tool_call_id: "t1", tool_name: "bash", arguments: %{}}],
        "/tmp/ws"
      )

    assert prompt =~ "please run the local check"
    assert prompt =~ "out of bounds"
    assert prompt =~ "/tmp/ws"
    assert prompt =~ "tool_call_id=t1"
    refute prompt =~ "SECRET_REASONING_abc"
    refute prompt =~ "HIDDEN_SUMMARY_xyz"
    assert AutoReview.policy_text() =~ "cookie"
    assert AutoReview.policy_text() =~ "tools.allow"
  end
end
