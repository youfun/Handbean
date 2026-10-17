defmodule Handbean.Agent.TurnCursorIdentityTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.{Config, Message, Turn}

  defmodule CaptureProvider do
    @behaviour Handbean.Agent.Provider

    def complete(_messages, _tools, config) do
      send(Process.whereis(:cursor_identity_test) || self(), {:provider_config, config})

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant("ok")],
         usage: %{input_tokens: 0, output_tokens: 1}
       }}
    end
  end

  test "Turn passes workspace and run_id through provider_config on the product path" do
    Process.register(self(), :cursor_identity_test)
    assert {:ok, _conversation} = Handbean.ConversationStore.create("workspace", id: "conv-1")

    config =
      Config.from_opts(
        provider: CaptureProvider,
        model: "composer-2.5",
        working_directory: "/tmp/product-ws",
        conversation_id: "conv-1",
        run_id: "run-product",
        provider_config: %{
          api: :cursor_agent,
          provider: "cursor",
          api_key: "tok",
          model: "composer-2.5"
        }
      )

    _state = Turn.run_loop(Handbean.Agent.State.init(config, "hi"), streaming: false)
    assert_receive {:provider_config, provider_config}, 1_000
    assert provider_config.working_directory == "/tmp/product-ws"
    assert provider_config.conversation_id == "conv-1"
    assert provider_config.run_id == "run-product"
  after
    Process.unregister(:cursor_identity_test)
  end
end
