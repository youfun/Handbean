defmodule Handbean.Platform.FileManagerTest.Unavailable do
  def available?, do: false
  def kind, do: :finder
  def reveal(_path), do: :ok
end

defmodule Handbean.Platform.FileManagerTest do
  use ExUnit.Case, async: false

  alias Handbean.Host
  alias Handbean.Platform.FileManager
  alias Handbean.Platform.FileManager.MacOS

  setup do
    previous = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    :ok
  end

  test "the facade exposes only an explicitly declared and available backend" do
    Application.delete_env(:handbean, :host)
    refute FileManager.available?()
    assert FileManager.kind() == nil
    assert FileManager.reveal("/tmp/file") == {:error, :unavailable}

    Host.put!(%{file_manager_backend: Handbean.Platform.FileManagerTest.Unavailable})
    refute FileManager.available?()
    assert FileManager.kind() == :finder
  end

  test "a callback backend receives the validated absolute path" do
    owner = self()

    Host.put!(%{
      file_manager_backend: fn path ->
        send(owner, {:revealed, path})
        :ok
      end
    })

    assert FileManager.available?()
    assert FileManager.kind() == :file_manager
    assert FileManager.reveal("/workspace/lib/a.ex") == :ok
    assert_received {:revealed, "/workspace/lib/a.ex"}
  end

  test "the macOS backend builds a fixed argument-vector command" do
    assert MacOS.command_spec("/workspace/-leading-name") ==
             {:ok, {"/usr/bin/open", ["-R", "--", "/workspace/-leading-name"]}}

    assert MacOS.command_spec("relative/file") == {:error, :invalid_path}
    assert MacOS.command_spec("/tmp/bad\0path") == {:error, :invalid_path}
  end

  test "the macOS backend maps runner status without invoking a shell" do
    owner = self()

    runner = fn executable, arguments, timeout ->
      send(owner, {:command, executable, arguments, timeout})
      {:ok, 0}
    end

    assert :ok = MacOS.reveal("/workspace/a.txt", runner: runner, timeout: 321)

    assert_received {:command, "/usr/bin/open", ["-R", "--", "/workspace/a.txt"], 321}

    assert MacOS.reveal("/workspace/a.txt", runner: fn _, _, _ -> {:ok, 7} end) ==
             {:error, {:exit_status, 7}}

    assert MacOS.reveal("/workspace/a.txt", runner: fn _, _, _ -> {:error, :timeout} end) ==
             {:error, :timeout}
  end
end
