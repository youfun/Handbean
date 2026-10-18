defmodule Handbean.SessionSupervisorTest do
  use ExUnit.Case, async: true

  alias Handbean.PubSub.Session

  test "start_or_get starts sessions under SessionSupervisor" do
    sid = "supervised-session-#{System.unique_integer([:positive])}"

    {:ok, pid} = Session.start_or_get(session_id: sid, model: "fake")

    supervised_pids =
      Handbean.SessionSupervisor.which_sessions()
      |> Enum.map(fn {_, child_pid, _, _} -> child_pid end)

    assert pid in supervised_pids
    assert Session.whereis(sid) == pid
  end

  test "concurrent start_or_get calls converge on one pid" do
    sid = "concurrent-session-#{System.unique_integer([:positive])}"

    results =
      1..8
      |> Task.async_stream(fn _ -> Session.start_or_get(session_id: sid, model: "fake") end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert results |> Enum.uniq() |> length() == 1
    assert Session.whereis(sid) == hd(results)
  end
end
