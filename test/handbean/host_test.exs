defmodule Handbean.HostTest.CLI do
end

defmodule Handbean.HostTest do
  use ExUnit.Case, async: false

  alias Handbean.Host

  setup do
    previous = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    :ok
  end

  test "desktop defaults keep shell and drop eval" do
    Application.delete_env(:handbean, :host)
    assert Host.shell?()
    assert Host.shell_jobs?()
    assert Host.shell_isolation() == :platform_required
    assert Host.terminal?()
    assert Host.browser_backend() == :cli
    assert Host.artifact_delivery_backend() == nil
    assert Host.file_manager_backend() == nil
    refute Host.host_script?()
    refute Host.beam_eval?()
    refute Host.configured?()
    refute Host.packaged_mix_toolchain?()
    assert Host.get(:git_backend) == nil
    assert Host.speech_backend() == Handbean.Speech.WhisperCpp
    assert Handbean.Git.backend() == Handbean.Git.CLI
    assert Handbean.Git.backend_kind() == :host_git_cli
  end

  test "phone host disables shell and desktop browser" do
    Host.put!(%{
      data_dir: "/tmp/mob-data",
      priv_dir: "/tmp/mob-beams/priv",
      shell: false,
      shell_jobs: false,
      shell_isolation: :none,
      terminal: false,
      browser_backend: :webview,
      speech_backend: nil,
      beam_eval: false,
      mcp: false,
      dist: true,
      packaged_mix_toolchain: true
    })

    assert Host.configured?()
    refute Host.shell?()
    refute Host.shell_jobs?()
    assert Host.shell_isolation() == :none
    refute Host.terminal?()
    assert Host.browser_backend() == :webview
    assert Host.speech_backend() == nil
    assert Host.artifact_delivery_backend() == nil
    refute Host.host_script?()
    refute Host.beam_eval?()
    refute Host.mcp?()
    assert Host.dist?()
    assert Host.packaged_mix_toolchain?()
    assert Host.data_dir() == "/tmp/mob-data"
    assert Host.priv_dir() == "/tmp/mob-beams/priv"
    assert Host.get(:git_backend) == nil
  end

  test "unknown shell isolation fails closed" do
    Host.put!(%{shell: true, shell_isolation: :invented})
    assert Host.shell_isolation() == :invalid
    refute Handbean.Platform.ProcessSandbox.os_enforced?()
  end

  test "backend_kind uses module identity rather than a .CLI name suffix" do
    Host.put!(%{git_backend: Handbean.HostTest.CLI})
    assert Handbean.Git.backend() == Handbean.HostTest.CLI
    assert Handbean.Git.backend_kind() == :injected

    Host.put!(%{git_backend: Handbean.Git.CLI})
    assert Handbean.Git.backend_kind() == :host_git_cli
  end

  test "explicit git_backend is returned as-is and is not inferred from shell" do
    Host.put!(%{shell: false, git_backend: Handbean.Git.CLI})
    assert Host.get(:git_backend) == Handbean.Git.CLI
    assert Handbean.Git.backend() == Handbean.Git.CLI

    Host.put!(%{shell: false, browser_backend: :webview})
    assert Host.get(:git_backend) == nil
    assert Handbean.Git.backend() == Handbean.Git.CLI
  end

  test "an explicit browser backend is not inferred from another capability" do
    Host.put!(%{browser_backend: :webview, artifact_delivery_backend: nil, host_script: false})
    assert Host.browser_backend() == :webview
    assert Host.artifact_delivery_backend() == nil
    refute Host.host_script?()

    Host.put!(%{browser_backend: nil, shell: false})
    assert Host.browser_backend() == nil
  end

  test "unknown host keys and unrelated booleans are not inferred as backends" do
    Host.put!(%{
      desktop_browser: false,
      webview_browser: true,
      system_intents: true,
      host_script_backend: :ignored
    })

    assert Host.browser_backend() == :cli
    assert Host.artifact_delivery_backend() == nil
    refute Host.host_script?()
    refute Map.has_key?(Application.get_env(:handbean, :host), :system_intents)
    refute Map.has_key?(Application.get_env(:handbean, :host), :webview_browser)
    refute Map.has_key?(Application.get_env(:handbean, :host), :host_script_backend)
  end

  describe "file_manager_backend/0" do
    test "is absent unless the host explicitly declares it" do
      Application.delete_env(:handbean, :host)
      assert Host.file_manager_backend() == nil

      Host.put!(%{shell: true})
      assert Host.file_manager_backend() == nil
    end

    test "returns a module or callback without inferring it from another capability" do
      callback = fn path -> {:ok, path} end
      Host.put!(%{file_manager_backend: callback})
      assert Host.file_manager_backend() == callback

      Host.put!(%{file_manager_backend: Handbean.Platform.FileManager.MacOS})
      assert Host.file_manager_backend() == Handbean.Platform.FileManager.MacOS
    end
  end

  describe "request_directory_picker/1" do
    test "is unavailable when no host installed a picker" do
      Application.delete_env(:handbean, :host)
      assert Host.request_directory_picker(%{purpose: :add_workspace}) == {:error, :unavailable}

      Host.put!(%{shell: false})
      assert Host.request_directory_picker() == {:error, :unavailable}
    end

    test "calls a fun/1 picker with the context" do
      parent = self()
      Host.put!(%{directory_picker: fn ctx -> send(parent, {:picked, ctx}) end})

      assert Host.request_directory_picker(%{purpose: :add_workspace})
      assert_received {:picked, %{purpose: :add_workspace}}
    end

    test "calls a module picker" do
      defmodule PickerStub do
        def request_directory_picker(ctx), do: {:ok, ctx}
      end

      Host.put!(%{directory_picker: PickerStub})
      assert Host.request_directory_picker(%{purpose: :test}) == {:ok, %{purpose: :test}}
    end
  end
end
