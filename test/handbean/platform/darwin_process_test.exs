defmodule Handbean.Platform.DarwinProcessTest do
  use ExUnit.Case, async: false

  @moduletag :darwin_process

  alias Handbean.Platform.{ProcessManager, ProcessRunner}

  test "the packaged Darwin process backend is available" do
    assert :handbean_darwin_process.available()
    assert ProcessManager.jobs_supported?()
  end

  test "a mismatched monotonic start identity is rejected without signalling the group" do
    {:ok, port, pid} = ProcessRunner.open_gated_bash("printf must_not_run", File.cwd!())
    on_exit(fn -> close_port(port) end)

    assert {:ok, start_sec, start_usec, start_abstime} =
             :handbean_darwin_process.verify_group(pid)

    assert {:error, :identity_mismatch} =
             :handbean_darwin_process.cleanup_group(
               pid,
               start_sec,
               start_usec,
               start_abstime + 1
             )

    assert Port.info(port) != nil

    assert :ok =
             :handbean_darwin_process.cleanup_group(
               pid,
               start_sec,
               start_usec,
               start_abstime
             )
  end

  test "invalid cleanup identities are rejected before any signal" do
    assert_raise ArgumentError, fn ->
      :handbean_darwin_process.cleanup_group(1, 0, 0, 0)
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
