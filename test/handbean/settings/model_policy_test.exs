defmodule Handbean.Settings.ModelPolicyTest do
  use ExUnit.Case, async: true

  alias Handbean.Settings.ModelPolicy
  alias Handbean.WorkspaceSettings

  setup do
    ws = Path.join(System.tmp_dir!(), "sigil_model_policy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    %{ws: ws}
  end

  test "no policy is unrestricted and unconfigured", %{ws: ws} do
    assert ModelPolicy.form(ws) ==
             %{mode: :unrestricted, allowed: %{}, default_model: nil, configured?: false}
  end

  test "empty allowlist is configured but unrestricted", %{ws: ws} do
    assert :ok = ModelPolicy.save(ws, %{mode: :unrestricted})
    assert %{mode: :unrestricted, configured?: true, allowed: %{}} = ModelPolicy.form(ws)
  end

  test "restricted form round-trips, drops empty providers, sorts models", %{ws: ws} do
    :ok =
      ModelPolicy.save(ws, %{
        mode: :restricted,
        allowed: %{"a" => MapSet.new(["z", "m"]), "b" => MapSet.new()},
        default_model: "a/m"
      })

    {:ok, policy} = WorkspaceSettings.models_policy(ws)
    assert policy["allow"]["providers"] == %{"a" => %{"models" => ["m", "z"]}}
    assert policy["default"] == %{"provider" => "a", "model" => "m"}

    form = ModelPolicy.form(ws)
    assert form.mode == :restricted
    assert form.allowed == %{"a" => MapSet.new(["m", "z"])}
    assert form.default_model == "a/m"
    assert form.configured?
  end

  test "a non-composite default is not written", %{ws: ws} do
    :ok =
      ModelPolicy.save(ws, %{
        mode: :restricted,
        allowed: %{"a" => MapSet.new(["m"])},
        default_model: "m"
      })

    {:ok, policy} = WorkspaceSettings.models_policy(ws)
    refute Map.has_key?(policy, "default")
  end

  test "malformed settings file is reported as :invalid, not raised", %{ws: ws} do
    path = WorkspaceSettings.path(ws)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{ broken")

    assert %{mode: :invalid, configured?: true, error: reason} = ModelPolicy.form(ws)
    assert reason =~ "Failed to parse"
  end

  test "default_model/1 reads only well-formed defaults" do
    assert ModelPolicy.default_model(%{"default" => %{"provider" => "a", "model" => "m"}}) ==
             "a/m"

    assert ModelPolicy.default_model(%{"default" => %{"provider" => "a"}}) == nil
    assert ModelPolicy.default_model(%{"default" => "a/m"}) == nil
    assert ModelPolicy.default_model(%{}) == nil
  end

  test "unknown form shape is rejected", %{ws: ws} do
    assert {:error, :invalid_policy} = ModelPolicy.save(ws, %{mode: :other})
  end
end
