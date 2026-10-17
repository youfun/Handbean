defmodule Handbean.RuntimeTest do
  use ExUnit.Case, async: false

  test "cancel_all_runs is a no-op without runners" do
    assert :ok = Handbean.Runtime.cancel_all_runs()
  end
end
