defmodule Handbean.Agent.AdvisorTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Advisor
  alias Handbean.Agent.Delegation.Policy
  alias Handbean.Agent.Subagent.Profile
  alias Handbean.Tool.Builtin.Advisor, as: AdvisorTool

  # Failure list:
  # - the Delegation wrapper JSON is not the advisor verdict
  # - the child report string is what consult and review parse

  test "consult and review use the same advisor budget" do
    for kind <- [:consult, :review] do
      profile = Profile.advisor(kind)

      assert profile.timeout_ms == 300_000
      assert profile.max_turns == 8
      assert Policy.budget(:advisor, kind) == {:ok, 300_000}
    end

    assert Advisor.consult_timeout_ms() == 300_000
    assert Advisor.review_timeout_ms() == 300_000
    assert AdvisorTool.timeout_ms() == 300_000
  end

  test "child_text returns the advisor report, not the delegation wrapper" do
    wrapper = %{
      status: :completed,
      child_conversation_id: "child",
      report: ~s({"verdict":"pass","findings":[]})
    }

    assert Advisor.child_text({:ok, "Delegated report\n{}", wrapper}) ==
             ~s({"verdict":"pass","findings":[]})
  end

  test "a wrapper without a report is not treated as advisor text" do
    assert Advisor.child_text({:ok, ~s({"status":"completed"}), %{status: :completed}}) == nil
  end
end
