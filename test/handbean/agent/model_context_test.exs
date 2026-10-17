defmodule Handbean.Agent.ModelContextTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.{Config, Message, ModelContext, State}
  alias Handbean.Agent.Provider

  defmodule HiddenContext do
    def context_editing?, do: false
  end

  test "install drops server continuation and bumps the context generation" do
    config = Config.from_opts(provider: Handbean.Agent.Provider.OpenAI, provider_config: %{})

    state = %State{
      config: config,
      messages: [Message.user("task"), Message.user("verbose log")],
      provider_state: %{response_id: "resp_old", context_generation: 0},
      context_generation: 0
    }

    installed = ModelContext.install(state, [Message.user("task"), Message.user("short")])

    assert installed.context_generation == 1
    refute Map.has_key?(installed.provider_state, :response_id)
    refute Map.has_key?(installed.provider_state, :context_generation)

    continued = State.merge_provider_state(installed, %{response_id: "resp_new"})
    assert continued.provider_state.response_id == "resp_new"
    assert continued.provider_state.context_generation == 1
  end

  test "install leaves continuation alone when the visible context did not change" do
    config = Config.from_opts(provider: Handbean.Agent.Provider.OpenAI, provider_config: %{})
    messages = [Message.user("task")]

    state = %State{
      config: config,
      messages: messages,
      provider_state: %{response_id: "resp_old"},
      context_generation: 0
    }

    assert ModelContext.install(state, messages).provider_state == %{response_id: "resp_old"}
  end

  test "install starts a new Cursor session instead of continuing the old one" do
    config =
      Config.from_opts(
        provider: Handbean.Agent.Provider.Cursor,
        provider_config: %{provider: "cursor"},
        model: "composer"
      )

    state = %State{
      config: config,
      messages: [Message.user("task"), Message.user("old")],
      provider_state: %{cursor_session_id: "session-old"},
      context_generation: 2
    }

    installed = ModelContext.install(state, [Message.user("task"), Message.user("new")])

    assert installed.provider_state.cursor_session_id != "session-old"
    assert String.starts_with?(installed.provider_state.cursor_session_id, "context-3-")
  end

  test "note_anchor counts cache reads and writes toward the context window" do
    state = %State{messages: [Message.user("task")]}

    cached =
      ModelContext.note_anchor(
        state,
        %{
          input_tokens: 1_000,
          cache_read_input_tokens: 180_000,
          cache_creation_input_tokens: 9_000,
          total_input_tokens: 190_000
        },
        1
      )

    assert cached.usage_anchor == %{input_tokens: 190_000, sent_count: 1}

    summed =
      ModelContext.note_anchor(
        state,
        %{
          "input_tokens" => 1_000,
          "cache_read_input_tokens" => 180_000,
          "cache_creation_input_tokens" => 9_000
        },
        1
      )

    assert summed.usage_anchor.input_tokens == 190_000

    inclusive =
      ModelContext.note_anchor(
        state,
        %{
          input_tokens: 2_600,
          total_input_tokens: 2_600,
          cache_read_input_tokens: 2_000,
          cache_creation_input_tokens: 400
        },
        1
      )

    assert inclusive.usage_anchor.input_tokens == 2_600
    assert ModelContext.note_anchor(state, %{input_tokens: 0}, 1).usage_anchor == nil
  end

  test "a read_context result does not block editing a sibling result" do
    messages = [
      Message.user("task"),
      Message.assistant_blocks([
        %{type: "tool_use", id: "view", name: "read_context", input: %{}},
        %{type: "tool_use", id: "bash1", name: "bash", input: %{}}
      ]),
      Message.tool_results([
        %{type: "tool_result", tool_use_id: "view", content: "dump without the marker"},
        %{type: "tool_result", tool_use_id: "bash1", content: "SIBLING-MARKER\nraw log"}
      ])
    ]

    assert {:ok, revised} = ModelContext.replace(messages, "SIBLING-MARKER", "kept")
    results = Enum.at(revised, 2).content
    assert Enum.at(results, 0).content == "[Earlier context view omitted after edit.]"
    assert Enum.at(results, 1).content == "kept\nraw log"
  end

  test "context tools are hidden unless the provider can apply an edited transcript" do
    defs = [
      %{name: "read_context", description: "", input_schema: %{}},
      %{name: "read", description: "", input_schema: %{}}
    ]

    assert Provider.filter_context_tools(defs, HiddenContext) == [
             %{name: "read", description: "", input_schema: %{}}
           ]

    assert Provider.context_editing?(Handbean.Agent.Provider.Anthropic)
    assert Provider.context_editing?(Handbean.Agent.Provider.OpenAI)
    assert Provider.context_editing?(Handbean.Agent.Provider.DeepSeek)
    assert Provider.context_editing?(Handbean.Agent.Provider.OpenRouter)
    assert Provider.context_editing?(Handbean.Agent.Provider.StepFun)
    assert Provider.context_editing?(Handbean.Agent.Provider.ZenMux)
    refute Provider.context_editing?(Handbean.Agent.Provider.Cursor)
    refute Provider.context_editing?(HiddenContext)
  end
end
