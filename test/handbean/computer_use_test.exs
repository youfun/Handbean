defmodule Handbean.ComputerUseTest do
  use ExUnit.Case, async: false

  defmodule Backend do
    def status do
      {:ok,
       %{
         "screen_recording" => true,
         "accessibility" => false,
         "event_post" => true,
         "actions" => %{"click" => false, "type" => true}
       }}
    end

    def stop_all do
      if owner = Application.get_env(:handbean, :computer_use_test_owner),
        do: send(owner, :computer_use_stopped)

      {:ok, %{}}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    old_host = Application.get_env(:handbean, :host)
    old_settings = System.get_env("HANDBEAN_GLOBAL_SETTINGS_FILE")
    settings_path = Path.join(tmp_dir, "settings.json")
    System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", settings_path)
    Application.put_env(:handbean, :computer_use_test_owner, self())

    on_exit(fn ->
      if old_host,
        do: Application.put_env(:handbean, :host, old_host),
        else: Application.delete_env(:handbean, :host)

      if old_settings,
        do: System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", old_settings),
        else: System.delete_env("HANDBEAN_GLOBAL_SETTINGS_FILE")

      Application.delete_env(:handbean, :computer_use_test_owner)
    end)

    :ok
  end

  @tag :tmp_dir
  test "defaults off and cannot enable without an explicit host backend" do
    Handbean.Host.put!(%{})

    refute Handbean.ComputerUse.supported?()
    refute Handbean.ComputerUse.enabled?()
    assert {:error, :unavailable} = Handbean.ComputerUse.set_enabled(true)
    refute Handbean.ComputerUse.enabled?()

    policy =
      Handbean.Permissions.ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "yolo"}})

    assert Handbean.Permissions.ToolPolicy.decision(policy, computer_call("observe")) == :deny
    assert Handbean.Permissions.ToolPolicy.decision(policy, computer_call("stop")) == :auto
  end

  @tag :tmp_dir
  test "persists enablement and projects native status without owning permissions" do
    Handbean.Host.put!(%{computer_use_backend: Backend})

    assert :ok = Handbean.ComputerUse.set_enabled(true)
    assert Handbean.ComputerUse.enabled?()

    policy =
      Handbean.Permissions.ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

    assert Handbean.Permissions.ToolPolicy.decision(policy, computer_call("list")) == :auto
    assert Handbean.Permissions.ToolPolicy.decision(policy, computer_call("observe")) == :auto
    assert Handbean.Permissions.ToolPolicy.decision(policy, computer_call("type")) == :prompt

    assert %{
             supported: true,
             enabled: true,
             backend: :custom,
             permissions: %{
               screen_recording: true,
               accessibility: false,
               event_post: true
             },
             actions: %{"click" => false, "type" => true}
           } = Handbean.ComputerUse.status()

    assert :ok = Handbean.ComputerUse.set_enabled(false)
    assert_receive :computer_use_stopped
    refute Handbean.ComputerUse.enabled?()
  end

  defp computer_call(action) do
    %{id: "call_computer", name: "computer", input: %{"action" => action}}
  end
end
