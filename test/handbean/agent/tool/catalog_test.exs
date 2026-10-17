defmodule Handbean.Agent.Tool.CatalogTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.{Config, State}
  alias Handbean.Agent.Tool.Catalog

  setup do
    Enum.each([Handbean.Tool.Builtin.Read, Handbean.Tool.Builtin.Write], fn module ->
      :ok = Handbean.Tool.Registry.register(module)
    end)

    :ok
  end

  test "assembles the session active set for provider declaration" do
    session_id = "catalog-active-#{System.unique_integer([:positive])}"
    :ok = Handbean.Tool.Registry.set_active_for_session(session_id, ["read"])
    on_exit(fn -> Handbean.Tool.Registry.set_active_for_session(session_id, nil) end)

    state =
      State.init(
        %Config{
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          max_turns: 5,
          context: %{}
        },
        "hello"
      )

    names = state |> Catalog.active_defs(session_id: session_id) |> Enum.map(& &1.name)

    assert names == ["read"]
  end

  test "final turn suppresses tools and requests a complete answer" do
    state =
      State.init(
        %Config{
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          max_turns: 1,
          context: %{}
        },
        "finish"
      )

    {provider_config, tool_defs} =
      Catalog.for_completion(state, [], %{system_prompt: "base prompt"})

    assert tool_defs == []
    assert provider_config.system_prompt =~ "base prompt"
    assert provider_config.system_prompt =~ "final agent step"
    assert provider_config.system_prompt =~ "Do not call tools"
  end

  test "unlimited turns retain the assembled tools and prompt" do
    state =
      State.init(
        %Config{
          provider: Handbean.TestSupport.FakeProvider,
          model: "fake",
          max_turns: nil,
          context: %{}
        },
        "continue"
      )

    {provider_config, tool_defs} =
      Catalog.for_completion(state, [], %{system_prompt: "base prompt"})

    assert tool_defs != []
    assert provider_config.system_prompt == "base prompt"
  end
end
