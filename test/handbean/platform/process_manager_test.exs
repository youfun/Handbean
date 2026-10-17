defmodule Handbean.Platform.ProcessManagerTest do
  use ExUnit.Case, async: true

  alias Handbean.Platform.ProcessManager

  describe "kill_process_tree/1" do
    test "returns :ok for nil pid" do
      assert :ok = ProcessManager.kill_process_tree(nil)
    end

    test "returns :ok for valid pid (process may already be dead)" do
      port = Port.open({:spawn, "sleep 0.1"}, [:binary])
      os_pid = port_info_os_pid(port)

      if Port.info(port) do
        Port.close(port)
      end

      # Process likely exited, but kill should not crash
      assert :ok = ProcessManager.kill_process_tree(os_pid)
    end

    test "does not raise on invalid pid" do
      assert :ok = ProcessManager.kill_process_tree(-1)
    end
  end

  describe "kill_process_group/1" do
    test "does not signal an unverified process group" do
      assert :ok = ProcessManager.kill_process_group(nil)
      assert :ok = ProcessManager.kill_process_group(-1)
      assert :ok = ProcessManager.kill_process_group(999_999_999)
    end
  end

  defp port_info_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end
end
