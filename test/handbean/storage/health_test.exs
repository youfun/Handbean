defmodule Handbean.Storage.HealthTest do
  use ExUnit.Case, async: false

  alias Handbean.Storage.Health

  setup do
    previous = :sys.get_state(Health)
    :sys.replace_state(Health, fn _state -> :healthy end)
    on_exit(fn -> :sys.replace_state(Health, fn _state -> previous end) end)
    :ok
  end

  test "opens the write circuit for corruption but not transient contention" do
    assert :busy = Health.report("database is locked")
    assert :healthy = Health.status()
    assert :ok = Health.check_write()

    assert :corrupt = Health.report("database disk image is malformed")
    assert {:open, :corrupt} = Health.status()
    assert {:error, :storage_unavailable} = Health.check_write()
  end
end
