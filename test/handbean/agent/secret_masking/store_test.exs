defmodule Handbean.Agent.SecretMasking.StoreTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Message
  alias Handbean.Agent.SecretMasking.Store
  alias Handbean.Agent.SecretMasking.Transformer

  @secret "sk-proj-abcdefghijklmnopqrstuvwxyz123456"

  setup do
    directory =
      Path.join(System.tmp_dir!(), "handbean-secret-store-#{System.unique_integer([:positive])}")

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")
    pid = start_supervised!({Store, name: name, directory: directory})
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, store: pid}
  end

  test "masks normalized semantic fields while preserving protocol and opaque data", %{
    store: store
  } do
    messages = [
      Message.assistant_blocks([
        %{type: "thinking", thinking: "signed #{@secret}", signature: "signed-by-provider"},
        %{type: "redacted_thinking", data: "opaque #{@secret}"},
        %{type: "image", mime_type: "image/png", data: @secret},
        %{
          type: "tool_use",
          id: "call-#{@secret}",
          name: "lookup_#{@secret}",
          input: %{"signature" => @secret, id: @secret, data: @secret}
        }
      ]),
      Message.user("API key: #{@secret}")
    ]

    tools = [
      %{
        name: "tool_#{@secret}",
        description: "uses #{@secret}",
        input_schema: %{
          type: "object",
          description: "top #{@secret}",
          properties: %{
            value: %{type: "string", description: "nested #{@secret}", enum: [@secret]}
          }
        }
      }
    ]

    config = %{
      system_prompt: "system #{@secret}",
      api_key: @secret,
      provider_state: %{token: @secret}
    }

    assert {:ok, prepared} = Store.prepare(messages, tools, config, store)
    assert [{placeholder, @secret}] = Map.to_list(prepared.restore)
    assert placeholder =~ ~r/^\{\{API_KEY_[a-z2-7]{8}\}\}$/

    [assistant, user] = prepared.messages
    [thinking, redacted, image, tool_use] = assistant.content

    assert thinking.thinking == "signed #{placeholder}"
    assert thinking.signature == "signed-by-provider"
    assert redacted.data == "opaque #{@secret}"
    assert image.data == @secret
    assert tool_use.id == "call-#{@secret}"
    assert tool_use.name == "lookup_#{@secret}"
    assert tool_use.input == %{"signature" => placeholder, id: placeholder, data: placeholder}
    assert user.content == "API key: #{placeholder}"

    [tool] = prepared.tools
    assert tool.name == "tool_#{@secret}"
    assert tool.description == "uses #{placeholder}"
    assert tool.input_schema.description == "top #{placeholder}"
    assert tool.input_schema.properties.value.description == "nested #{placeholder}"
    assert tool.input_schema.properties.value.enum == [@secret]

    assert prepared.config.system_prompt == "system #{placeholder}"
    assert prepared.config.api_key == @secret
    assert prepared.config.provider_state == %{token: @secret}
  end

  test "restores semantic completion fields but not provider metadata", %{store: store} do
    assert {:ok, prepared} = Store.prepare([Message.user("api_key=#{@secret}")], [], %{}, store)
    [{placeholder, @secret}] = Map.to_list(prepared.restore)

    response = %{
      stop_reason: :tool_use,
      messages: [
        Message.assistant_blocks([
          %{type: "text", text: "answer #{placeholder}"},
          %{type: "thinking", thinking: placeholder, signature: "sig"},
          %{type: "tool_use", id: placeholder, name: placeholder, input: %{key: placeholder}}
        ])
      ],
      usage: %{raw: placeholder},
      provider_state: %{encrypted_content: placeholder},
      response_metadata: %{id: placeholder}
    }

    assert {:ok, restored} = Transformer.restore_response(response, prepared.restore)
    [message] = restored.messages
    [text, thinking, tool_use] = message.content
    assert text.text == "answer #{@secret}"
    assert thinking.thinking == @secret
    assert thinking.signature == "sig"
    assert tool_use.id == placeholder
    assert tool_use.name == placeholder
    assert tool_use.input == %{key: @secret}
    assert restored.usage == response.usage
    assert restored.provider_state == response.provider_state
    assert restored.response_metadata == response.response_metadata
  end

  test "known values remain masked without rewriting a previously sent prefix", %{store: store} do
    contextual_secret = "AlphaSecret12345"
    historical = "historical mention #{contextual_secret}"

    assert {:ok, first} = Store.prepare([Message.user(historical)], [], %{}, store)
    assert hd(first.messages).content == historical

    assert {:ok, detected} =
             Store.prepare([Message.user("api_key=#{contextual_secret}")], [], %{}, store)

    [{placeholder, ^contextual_secret}] = Map.to_list(detected.restore)

    assert {:ok, known} =
             Store.prepare([Message.user("repeat #{contextual_secret}")], [], %{}, store)

    assert hd(known.messages).content == "repeat #{placeholder}"

    assert {:ok, replayed} = Store.prepare([Message.user(historical)], [], %{}, store)
    assert hd(replayed.messages).content == historical
  end

  test "rejects unknown content blocks instead of sending them unchanged", %{store: store} do
    message = Message.assistant_blocks([%{type: "extension_private", payload: @secret}])

    assert {:error, {:unknown_content_block, "extension_private"}} =
             Store.prepare([message], [], %{}, store)
  end

  test "stores only a private HMAC key on disk", %{directory: directory, store: store} do
    assert {:ok, _prepared} = Store.prepare([Message.user("api_key=#{@secret}")], [], %{}, store)

    key_path = Path.join(directory, "key")
    assert {:ok, key} = File.read(key_path)
    assert byte_size(key) == 32
    refute key =~ @secret

    assert {:ok, %{mode: directory_mode}} = File.lstat(directory)
    assert {:ok, %{mode: key_mode}} = File.lstat(key_path)
    assert Bitwise.band(directory_mode, 0o077) == 0
    assert Bitwise.band(key_mode, 0o077) == 0
  end

  test "reuses the HMAC key across Store instances", %{directory: directory, store: store} do
    assert {:ok, first} = Store.prepare([Message.user("api_key=#{@secret}")], [], %{}, store)
    [{first_placeholder, @secret}] = Map.to_list(first.restore)

    name = Module.concat(__MODULE__, "RestartedStore#{System.unique_integer([:positive])}")

    restarted =
      start_supervised!(
        Supervisor.child_spec({Store, name: name, directory: directory}, id: name)
      )

    assert {:ok, second} =
             Store.prepare([Message.user("api_key=#{@secret}")], [], %{}, restarted)

    assert [{^first_placeholder, @secret}] = Map.to_list(second.restore)
  end

  test "rejects a symbolic link in place of the persisted key", %{
    directory: directory,
    store: store
  } do
    target = Path.join(directory, "target")
    File.mkdir_p!(directory)
    File.write!(target, :crypto.strong_rand_bytes(32))
    File.chmod!(target, 0o600)
    File.ln_s!(target, Path.join(directory, "key"))

    assert {:error, :secret_masking_storage_failed} =
             Store.prepare([Message.user("api_key=#{@secret}")], [], %{}, store)
  end

  test "fails closed when the persisted key has an invalid length", %{
    directory: directory,
    store: store
  } do
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    File.write!(Path.join(directory, "key"), "short")
    File.chmod!(Path.join(directory, "key"), 0o600)

    assert {:error, :invalid_secret_masking_key} =
             Store.prepare([Message.user("api_key=#{@secret}")], [], %{}, store)
  end
end
