defmodule Handbean.Agent.ProviderGatewayTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.{Message, ProviderGateway}
  alias Handbean.Agent.SecretMasking.Store
  alias Handbean.Settings.Security

  @secret "sk-proj-abcdefghijklmnopqrstuvwxyz123456"

  defmodule CapturingProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, tools, config) do
      send(config.test_pid, {:provider_request, messages, tools, config})
      text = Message.text(hd(messages))
      [placeholder] = Regex.run(~r/\{\{API_KEY_[a-z2-7]{8,52}\}\}/, text)

      if on_chunk = config[:on_chunk] do
        {left, right} = String.split_at(placeholder, 7)
        on_chunk.("before " <> left)
        if on_event = config[:on_event], do: on_event.({:thinking_delta, "thinking"})
        on_chunk.(right <> " after")
      end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant("response #{placeholder}")],
         usage: %{},
         provider_state: %{opaque: placeholder},
         response_metadata: %{id: placeholder}
       }}
    end
  end

  defmodule PassthroughProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, tools, config) do
      send(config.test_pid, {:provider_request, messages, tools, config})
      {:ok, %{stop_reason: :end_turn, messages: messages, usage: %{}}}
    end
  end

  defmodule PartialErrorProvider do
    @behaviour Handbean.Agent.Provider

    @impl true
    def complete(messages, _tools, config) do
      text = Message.text(hd(messages))
      [placeholder] = Regex.run(~r/\{\{API_KEY_[a-z2-7]{8,52}\}\}/, text)
      {left, _right} = String.split_at(placeholder, 7)
      config.on_chunk.("pending " <> left)
      {:error, :provider_failed}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "handbean-provider-gateway-#{System.unique_integer([:positive])}"
      )

    settings_path = Path.join(root, "settings.json")
    store_dir = Path.join(root, "masking")
    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    store = start_supervised!({Store, name: name, directory: store_dir})

    previous_file = System.get_env("HANDBEAN_GLOBAL_SETTINGS_FILE")
    previous_store = Application.get_env(:handbean, :secret_masking_store)
    System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", settings_path)
    Application.put_env(:handbean, :secret_masking_store, store)

    on_exit(fn ->
      if previous_file,
        do: System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", previous_file),
        else: System.delete_env("HANDBEAN_GLOBAL_SETTINGS_FILE")

      if previous_store,
        do: Application.put_env(:handbean, :secret_masking_store, previous_store),
        else: Application.delete_env(:handbean, :secret_masking_store)

      File.rm_rf!(root)
    end)

    %{settings_path: settings_path, store_dir: store_dir}
  end

  test "masks provider input and restores ordered callbacks and completion fields" do
    assert :ok = Security.set_secret_masking(true)
    owner = self()

    config = %{
      test_pid: owner,
      on_chunk: fn chunk -> send(owner, {:chunk, chunk}) end,
      on_event: fn event -> send(owner, {:event, event}) end
    }

    assert {:ok, response} =
             ProviderGateway.complete(
               CapturingProvider,
               [Message.user("api_key=#{@secret}")],
               [],
               config
             )

    assert_receive {:provider_request, [masked_message], [], provider_config}
    refute masked_message.content =~ @secret
    assert masked_message.content =~ "{{API_KEY_"
    assert is_function(provider_config.on_chunk, 1)
    assert is_function(provider_config.on_event, 1)

    assert_receive {:chunk, "before "}
    assert_receive {:event, {:thinking_delta, "thinking"}}
    assert_receive {:chunk, @secret <> " after"}

    assert Message.text(hd(response.messages)) == "response #{@secret}"
    assert response.provider_state.opaque =~ "{{API_KEY_"
    assert response.response_metadata.id =~ "{{API_KEY_"
  end

  test "disabled setting is transparent and does not create a key", %{store_dir: store_dir} do
    assert {:ok, false} = Security.secret_masking_enabled?()

    assert {:ok, %{messages: [message]}} =
             ProviderGateway.complete(
               PassthroughProvider,
               [Message.user(@secret)],
               [],
               %{test_pid: self()}
             )

    assert message.content == @secret
    assert_receive {:provider_request, [%Message{content: @secret}], [], _config}
    refute File.exists?(store_dir)
  end

  test "a provider error discards buffered partial placeholders" do
    assert :ok = Security.set_secret_masking(true)
    owner = self()

    assert {:error, :provider_failed} =
             ProviderGateway.complete(
               PartialErrorProvider,
               [Message.user("api_key=#{@secret}")],
               [],
               %{on_chunk: fn chunk -> send(owner, {:chunk, chunk}) end}
             )

    refute_receive {:chunk, _chunk}
  end

  test "a corrupt security setting blocks the provider call", %{settings_path: settings_path} do
    File.mkdir_p!(Path.dirname(settings_path))
    File.write!(settings_path, "{broken")

    assert {:error, {:secret_masking_failed, reason}} =
             ProviderGateway.complete(
               PassthroughProvider,
               [Message.user(@secret)],
               [],
               %{test_pid: self()}
             )

    assert is_binary(reason)
    refute_receive {:provider_request, _messages, _tools, _config}
  end
end
