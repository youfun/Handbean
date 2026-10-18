defmodule Handbean.GuardTest do
  @moduledoc """
  Guards against merge regressions in host-capability tool seeding.

  `Handbean.Tool.Registry.host_tool_modules/0` owns the list and
  `Handbean.Agent.default_tools/0` delegates to it. Host backends are independent:
  a WebView browser does not imply artifact delivery or a host script runtime.
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent
  alias Handbean.Tool.Registry

  @delivery_tools MapSet.new(~w(open_url open_file share_file device_calendar device_alarm))
  @runtime_tools ~w(task task_status advisor list_models create_thread list_threads find_thread read_thread get_thread_status get_thread_trajectory send_thread_message reply_to_parent_thread publish_media mem_recall mem_learn)

  setup do
    previous = Application.get_env(:handbean, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end)

    :ok
  end

  test "Agent.default_tools/0 is the same list as Registry.host_tool_modules/0" do
    for host <- [
          nil,
          %{shell: false, browser_backend: :webview, beam_eval: false},
          %{
            shell: false,
            browser_backend: nil,
            artifact_delivery_backend: Handbean.ArtifactDelivery,
            host_script: false
          },
          %{shell: true, browser_backend: :cli, host_script: false}
        ] do
      put_host(host)
      assert Agent.default_tools() == Registry.host_tool_modules()
    end
  end

  test "desktop defaults register shell and CLI browser, not mobile backends" do
    put_host(nil)
    names = names(Registry.host_tool_modules())
    assert "bash" in names
    assert "browser" in names
    assert delivery(Registry.host_tool_modules()) == MapSet.new()
    refute "run_elixir_script" in names
    refute "git" in names
    refute "mix_project" in names
    refute "preview_serve" in names
    for tool <- @runtime_tools, do: assert(tool in names)
  end

  test "script, artifact delivery, and browser backends register independently" do
    put_host(%{
      shell: false,
      browser_backend: nil,
      artifact_delivery_backend: Handbean.ArtifactDelivery,
      host_script: false
    })

    mods = Registry.host_tool_modules()
    assert delivery(mods) == @delivery_tools
    refute "run_elixir_script" in names(mods)
    refute "browser" in names(mods)
    refute "preview_serve" in names(mods)

    put_host(%{
      shell: false,
      browser_backend: :webview,
      artifact_delivery_backend: nil,
      host_script: true
    })

    mods = Registry.host_tool_modules()
    assert delivery(mods) == MapSet.new()
    assert "run_elixir_script" in names(mods)
    assert "browser" in names(mods)
    assert "preview_serve" in names(mods)
  end

  test "a webview browser alone does not imply delivery or scripts" do
    put_host(%{shell: false, browser_backend: :webview, beam_eval: false})
    names = names(Registry.host_tool_modules())
    assert delivery(Registry.host_tool_modules()) == MapSet.new()
    refute "run_elixir_script" in names
    assert "browser" in names
    assert "task" in names
    assert "grep" in names
  end

  test "shell off does not remove runtime tools, and git off does not remove grep" do
    put_host(%{
      shell: false,
      browser_backend: nil,
      git_backend: nil,
      packaged_mix_toolchain: false
    })

    names = names(Registry.host_tool_modules())
    refute "bash" in names
    refute "git" in names
    refute "mix_project" in names

    for tool <- ~w(read write edit grep file_search code_search web_fetch),
        do: assert(tool in names)

    for tool <- @runtime_tools, do: assert(tool in names)
  end

  defp put_host(nil), do: Application.delete_env(:handbean, :host)
  defp put_host(host), do: Handbean.Host.put!(host)

  defp names(mods), do: Enum.map(mods, & &1.name())

  defp delivery(mods) do
    mods
    |> names()
    |> Enum.filter(&(&1 in @delivery_tools))
    |> MapSet.new()
  end
end
