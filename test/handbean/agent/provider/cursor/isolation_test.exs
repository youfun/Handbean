defmodule Handbean.Agent.Provider.Cursor.IsolationTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Config
  alias Handbean.Agent.Provider.Cursor

  test "config maps cursor provider to the Cursor module" do
    assert Config.resolve_provider_from_api(:cursor_agent, "composer-2.5", "cursor") == Cursor

    assert Config.resolve_provider_from_api(:openai_responses, "grok-4.6", "openai") ==
             Handbean.Agent.Provider.OpenAI
  end

  test "xAI oauth still resolves independently from Cursor" do
    assert Config.resolve_provider_from_api(:openai_responses, "grok-4.6", "xai") ==
             Handbean.Agent.Provider.OpenAI
  end
end
