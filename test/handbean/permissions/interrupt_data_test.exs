defmodule Handbean.Permissions.InterruptDataTest do
  use ExUnit.Case, async: true

  alias Handbean.Permissions.InterruptData

  test "action requests include a suggested remember pattern" do
    pending = [
      %{id: "b1", name: "bash", input: %{"command" => "git status --short"}}
    ]

    data = InterruptData.build(pending, [], "/tmp/ws")

    assert [%{tool_call_id: "b1", tool_name: "bash", suggested_pattern: "bash(git status*)"}] =
             data.action_requests
  end
end
