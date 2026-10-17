defmodule Handbean.Agent.Provider.CodexTest do
  # Stream boundary failures: a terminal output: [] must not discard completed
  # item events; absent/null output has the same fallback. A nonempty terminal
  # output remains authoritative and must not duplicate streamed items.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Handbean.CodexTestHelper

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Codex
  alias Handbean.Agent.Provider.Codex.Models
  alias Handbean.Agent.Auth.CodexCredential
  alias Handbean.CodexTestHelper.ReqMock

  defp config do
    %{api_key: token(), model: "gpt-5.4", req_options: [plug: {Req.Test, __MODULE__}]}
  end

  defp event(type, attrs), do: "data: " <> Jason.encode!(Map.put(attrs, "type", type)) <> "\n\n"

  defp text_item(text),
    do: %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }

  defp completed(output, usage \\ %{}) do
    event("response.completed", %{
      "response" => %{
        "id" => "response-a",
        "status" => "completed",
        "output" => output,
        "usage" => usage
      }
    })
  end

  defp sse(conn, body),
    do: conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)

  test "OAuth requests reject a replaced login rather than sending history to the new account" do
    dir = Path.join(System.tmp_dir!(), "codex-generation-#{System.unique_integer([:positive])}")
    previous = System.get_env("HANDBEAN_AUTH_FILE")
    System.put_env("HANDBEAN_AUTH_FILE", Path.join(dir, "auth.json"))

    on_exit(fn ->
      if previous,
        do: System.put_env("HANDBEAN_AUTH_FILE", previous),
        else: System.delete_env("HANDBEAN_AUTH_FILE")

      File.rm_rf!(dir)
    end)

    assert :ok = CodexCredential.store_login("openai_codex", credential())
    assert {:ok, auth} = CodexCredential.resolve_transport_key("openai_codex")
    options = Map.merge(config(), Map.put(auth, :auth_type, :oauth))

    Req.Test.stub(__MODULE__, fn conn ->
      assert get_req_header(conn, "chatgpt-account-id") == ["account-a"]
      sse(conn, completed([text_item("Original account")]))
    end)

    assert {:ok, _} = Codex.complete([Message.user("private history")], [], options)
    assert :ok = CodexCredential.store_login("openai_codex", credential("account-b"))
    Req.Test.stub(__MODULE__, fn _ -> flunk("Must not send history after login replacement") end)
    assert {:error, message} = Codex.complete([Message.user("private history")], [], options)
    assert message =~ "account changed"
  end

  test "Codex request uses subscription endpoint, instructions, strict fields and streaming text" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "chatgpt.com"
      assert conn.request_path == "/backend-api/codex/responses"
      assert get_req_header(conn, "chatgpt-account-id") == ["account-a"]
      assert get_req_header(conn, "authorization") == ["Bearer " <> token()]
      assert get_req_header(conn, "originator") == ["pi"]
      assert get_req_header(conn, "session-id") == ["session-a"]
      {:ok, body, conn} = read_body(conn)
      body = Jason.decode!(body)
      assert body["instructions"] == "Work carefully"
      assert body["store"] == false
      assert body["stream"] == true
      assert body["text"] == %{"verbosity" => "low"}
      assert body["prompt_cache_key"] == "session-a"
      assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "max_output_tokens")
      refute Map.has_key?(body, "previous_response_id")
      assert body["input"] == [%{"role" => "user", "content" => "hello"}]

      sse(
        conn,
        event("response.output_text.delta", %{"delta" => "Hello"}) <>
          completed([text_item("Hello")], %{
            "input_tokens" => 31,
            "output_tokens" => 7,
            "input_tokens_details" => %{"cached_tokens" => 11},
            "output_tokens_details" => %{"reasoning_tokens" => 3}
          })
      )
    end)

    options =
      Map.merge(config(), %{
        system_prompt: "Work carefully",
        max_tokens: 5,
        store: true,
        previous_response_id: "must-not-send",
        reasoning: %{effort: "high"},
        session_id: "session-a"
      })

    assert {:ok, result} =
             Codex.stream([Message.user("hello")], [], options, &send(owner, {:chunk, &1}))

    assert_received {:chunk, "Hello"}
    assert Message.text(hd(result.messages)) == "Hello"

    assert result.usage == %{
             input_tokens: 31,
             total_input_tokens: 31,
             output_tokens: 7,
             cache_read_input_tokens: 11,
             cache_creation_input_tokens: 0,
             reasoning_tokens: 3
           }

    assert result.provider_state == %{}
  end

  test "function call, encrypted reasoning and local tool output round trip preserve call IDs and order" do
    reasoning = %{
      "id" => "rs-1",
      "type" => "reasoning",
      "summary" => [],
      "encrypted_content" => "opaque"
    }

    call = %{
      "id" => "fc-item",
      "type" => "function_call",
      "call_id" => "call-42",
      "name" => "probe_lookup",
      "arguments" => ~s({"key":"violet-17"})
    }

    tool = %{
      name: "probe_lookup",
      description: "Read a key",
      input_schema: %{type: "object", properties: %{key: %{type: "string"}}}
    }

    Req.Test.stub(__MODULE__, &sse(&1, completed([reasoning, call])))
    assert {:ok, first} = Codex.complete([Message.user("Look up the key")], [tool], config())
    assert first.stop_reason == :tool_use

    assert [%{id: "call-42", name: "probe_lookup", input: %{"key" => "violet-17"}}] =
             Message.tool_calls(hd(first.messages))

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      body = Jason.decode!(body)

      assert [
               %{"role" => "user"},
               ^reasoning,
               %{"type" => "function_call", "call_id" => "call-42"},
               %{
                 "type" => "function_call_output",
                 "call_id" => "call-42",
                 "output" => "ORCHID-5928"
               }
             ] = body["input"]

      assert [%{"type" => "function", "name" => "probe_lookup"}] = body["tools"]
      refute Map.has_key?(hd(body["tools"]), "strict")
      sse(conn, completed([text_item("ORCHID-5928")]))
    end)

    messages =
      [Message.user("Look up the key")] ++
        first.messages ++
        [Message.tool_results([Message.tool_result_block("call-42", "ORCHID-5928")])]

    assert {:ok, final} = Codex.complete(messages, [tool], config())
    assert final.stop_reason == :end_turn
    assert Message.text(hd(final.messages)) == "ORCHID-5928"
  end

  test "commentary and final_answer stay separate and replay with phase" do
    owner = self()

    commentary = %{
      "id" => "msg_commentary",
      "type" => "message",
      "role" => "assistant",
      "phase" => "commentary",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "Hello! What can I help you with?"}]
    }

    final_answer = %{
      "id" => "msg_final",
      "type" => "message",
      "role" => "assistant",
      "phase" => "final_answer",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "Hello! How can I help?"}]
    }

    Req.Test.stub(__MODULE__, fn conn ->
      sse(
        conn,
        event("response.output_text.delta", %{
          "delta" => "Hello! What can I help you with?",
          "output_index" => 0
        }) <>
          event("response.output_item.done", %{"output_index" => 0, "item" => commentary}) <>
          event("response.output_item.added", %{"output_index" => 1, "item" => final_answer}) <>
          event("response.output_text.delta", %{
            "delta" => "Hello! How can I help?",
            "output_index" => 1
          }) <>
          event("response.output_item.done", %{"output_index" => 1, "item" => final_answer}) <>
          completed([commentary, final_answer])
      )
    end)

    assert {:ok, result} =
             Codex.stream([Message.user("hello")], [], config(), &send(owner, {:chunk, &1}))

    assert_received {:chunk, %{text: "Hello! What can I help you with?", phase: "commentary"}}
    assert_received {:chunk, %{text: "Hello! How can I help?", phase: "final_answer"}}

    assert [
             %{
               type: "text",
               text: "Hello! What can I help you with?",
               phase: "commentary",
               output_index: 0
             },
             %{
               type: "text",
               text: "Hello! How can I help?",
               phase: "final_answer",
               id: "msg_final",
               output_index: 1
             }
           ] = Enum.filter(hd(result.messages).content, &(&1.type == "text"))

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)

      assert [
               %{"role" => "user"},
               %{
                 "type" => "message",
                 "phase" => "commentary",
                 "id" => "msg_commentary",
                 "content" => [%{"text" => "Hello! What can I help you with?"}]
               },
               %{
                 "type" => "message",
                 "phase" => "final_answer",
                 "id" => "msg_final",
                 "content" => [%{"text" => "Hello! How can I help?"}]
               },
               %{"role" => "user", "content" => "again"}
             ] = Jason.decode!(body)["input"]

      sse(conn, completed([text_item("done")]))
    end)

    assert {:ok, _} =
             Codex.complete(
               [Message.user("hello"), hd(result.messages), Message.user("again")],
               [],
               config()
             )
  end

  test "replays persisted opaque reasoning for the same model and account" do
    item = %{"type" => "reasoning", "encrypted_content" => "persisted-secret"}

    message =
      Message.assistant_blocks([
        %{
          "type" => "responses_reasoning",
          "account_id" => "account-a",
          "model" => "gpt-5.4",
          "item" => item
        },
        %{type: "text", text: "Prior answer"}
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert [^item | _] = Jason.decode!(body)["input"]
      sse(conn, completed([text_item("ok")]))
    end)

    assert {:ok, _} = Codex.complete([message], [], config())
  end

  test "opaque reasoning is not replayed under another model or account" do
    message =
      Message.assistant_blocks([
        %{
          type: "codex_reasoning",
          account_id: "account-a",
          model: "gpt-5.4",
          item: %{"type" => "reasoning", "encrypted_content" => "secret"}
        },
        %{type: "text", text: "Prior answer"}
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      refute body =~ "secret"

      assert [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "status" => "completed",
                 "content" => [%{"type" => "output_text", "text" => "Prior answer"}]
               }
             ] = Jason.decode!(body)["input"]

      sse(conn, completed([text_item("ok")]))
    end)

    assert {:ok, _} = Codex.complete([message], [], %{config() | model: "different-model"})
    assert {:ok, _} = Codex.complete([message], [], %{config() | api_key: token("account-b")})
  end

  test "disconnect, failed and incomplete streams never yield executable tools" do
    call = %{
      "id" => "fc",
      "type" => "function_call",
      "call_id" => "call",
      "name" => "write",
      "arguments" => "{}"
    }

    partial = event("response.output_item.done", %{"output_index" => 0, "item" => call})

    for suffix <- [
          "",
          "data: [DONE]\n\n",
          event("response.failed", %{"error" => %{"message" => "secret"}}),
          event("response.incomplete", %{"response" => %{}})
        ] do
      Req.Test.stub(__MODULE__, &sse(&1, partial <> suffix))
      assert {:error, reason} = Codex.complete([Message.user("write")], [], config())
      refute reason =~ "secret"
    end
  end

  test "out of order completed item events are reassembled by output index" do
    for terminal <- [%{}, %{"output" => nil}, %{"output" => []}] do
      Req.Test.stub(
        __MODULE__,
        &sse(
          &1,
          event("response.output_item.done", %{"output_index" => 1, "item" => text_item("second")}) <>
            event("response.output_item.done", %{
              "output_index" => 0,
              "item" => text_item("first")
            }) <>
            event("response.done", %{"response" => Map.put(terminal, "status", "completed")})
        )
      )

      assert {:ok, result} = Codex.complete([Message.user("hi")], [], config())
      assert Message.text(hd(result.messages)) == "first\nsecond"

      assert [
               %{type: "text", text: "first", output_index: 0},
               %{type: "text", text: "second", output_index: 1}
             ] = hd(result.messages).content
    end
  end

  test "invalid function arguments, missing call ID and unknown native tools are rejected" do
    for item <- [
          %{"type" => "function_call", "call_id" => "c", "name" => "write", "arguments" => "[]"},
          %{
            "type" => "function_call",
            "id" => "not-a-call-id",
            "name" => "write",
            "arguments" => "{}"
          },
          %{"type" => "computer_call", "action" => "click"}
        ] do
      Req.Test.stub(__MODULE__, &sse(&1, completed([item])))

      assert {:error, "Invalid Codex output item. No tools were executed."} =
               Codex.complete([Message.user("hi")], [], config())
    end
  end

  test "a header-stage disconnect is replayed once and keeps the server reason" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, :attempt)

      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 ->
          Req.Test.transport_error(conn, :closed)

        _ ->
          {:ok, body, conn} = read_body(conn)
          assert Jason.decode!(body)["prompt_cache_key"] == "handbean"
          sse(conn, completed([text_item("recovered")]))
      end
    end)

    assert {:ok, result} = Codex.complete([Message.user("hi")], [], config())
    assert Message.text(hd(result.messages)) == "recovered"
    assert Agent.get(attempts, & &1) == 2
    assert_received :attempt
    assert_received :attempt
  end

  test "a second header-stage disconnect reports the transport reason" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :closed))
    assert {:error, reason} = Codex.complete([Message.user("hi")], [], config())
    assert reason =~ ":closed"
    assert reason =~ "replayed once"
    refute reason =~ "not replayed"
  end

  test "Codex error bodies are surfaced without echoing the raw payload" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: %{message: "unsupported model"}}))
    end)

    assert {:error, reason} = Codex.complete([Message.user("hi")], [], config())
    assert reason =~ "HTTP 400"
    assert reason =~ "unsupported model"
  end

  test "subscription limits are actionable and malformed credentials cannot use API billing" do
    Req.Test.stub(__MODULE__, &send_resp(&1, 429, "secret quota response"))
    assert {:error, reason} = Codex.complete([Message.user("hi")], [], config())
    assert reason =~ "usage limit"
    refute reason =~ "secret"

    Req.Test.stub(__MODULE__, fn _ ->
      flunk("Invalid credentials must not reach the transport")
    end)

    assert {:error, _} = Codex.complete([], [], %{config() | api_key: "sk-platform-key"})
  end

  test "Handbean Turn executes the local tool and feeds its real result into the next SSE request" do
    alias Handbean.Agent.{Config, State, Turn}
    registry = Handbean.Tool.Registry
    registry_state = :sys.get_state(registry)
    snapshot_sync_id = "codex-registry-sync-#{System.unique_integer([:positive])}"
    assert :ok = registry.register(Handbean.Tool.Builtin.Read)

    on_exit(fn ->
      :sys.replace_state(registry, fn _ -> registry_state end)
      assert :ok = registry.set_active_for_session(snapshot_sync_id, nil)
    end)

    dir = Path.join(System.tmp_dir!(), "codex-turn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "probe.txt"), "ORCHID-5928")
    on_exit(fn -> File.rm_rf!(dir) end)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      input = Jason.decode!(body)["input"]

      case Enum.find(input, &(&1["type"] == "function_call_output")) do
        nil ->
          refute body =~ "ORCHID-5928"

          call = %{
            "type" => "function_call",
            "call_id" => "read-local",
            "name" => "read",
            "arguments" => Jason.encode!(%{file_path: "probe.txt"})
          }

          sse(conn, completed([call]))

        result ->
          assert result["call_id"] == "read-local"
          assert result["output"] =~ "ORCHID-5928"
          send(owner, :local_result_returned)
          sse(conn, completed([text_item("Read ORCHID-5928")]))
      end
    end)

    runtime = %Config{
      provider: Codex,
      provider_config: config(),
      model: "gpt-5.4",
      working_directory: dir,
      middleware: [],
      max_turns: 3
    }

    result = Turn.run_loop(State.init(runtime, "Read probe.txt"), on_event: &send(owner, &1))
    assert result.status == :completed
    assert Message.text(List.last(result.messages)) == "Read ORCHID-5928"
    assert_received :local_result_returned
    assert_received {:tool_start, %{tool: "read", tool_use_id: "read-local"}}
    assert_received {:tool_end, %{tool: "read", tool_use_id: "read-local"}}
  end

  test "model catalog comes from the authenticated Codex endpoint and has unknown cost" do
    dir = Path.join(System.tmp_dir!(), "codex-models-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    opts = [auth_path: Path.join(dir, "auth.json"), req_module: ReqMock]
    assert :ok = CodexCredential.store_login("openai_codex", credential(), opts)

    Req.Test.stub(ReqMock, fn conn ->
      assert conn.host == "chatgpt.com"
      assert conn.request_path == "/backend-api/codex/models"
      assert conn.query_string =~ "client_version=0.163.0"
      refute conn.query_string =~ "client_version=0.1.0"
      assert get_req_header(conn, "chatgpt-account-id") == ["account-a"]

      Req.Test.json(conn, %{
        models: [
          %{
            slug: "model-visible",
            display_name: "Visible",
            context_window: 128_000,
            input_modalities: ["text", "image"],
            supported_reasoning_levels: [%{effort: "low"}, %{effort: "high"}],
            default_reasoning_level: "low"
          },
          %{slug: "model-hidden", visibility: "hide"}
        ]
      })
    end)

    assert {:ok, [model]} = Models.discover(opts)
    assert model["id"] == "model-visible"
    assert model["contextWindow"] == 128_000
    assert model["reasoning"]
    assert model["reasoningLevels"] == ["low", "high"]
    assert model["defaultReasoning"] == "low"
    refute Map.has_key?(model, "cost")

    assert Models.preserve_enabled(
             [%{"id" => "gpt-6.1-sol", "name" => "GPT-6.1-Sol"}, %{"id" => "kept"}],
             [%{"id" => "kept", "enabled" => false}, %{"id" => "gone", "enabled" => true}]
           ) == [
             %{"id" => "gpt-6.1-sol", "name" => "GPT-6.1-Sol"},
             %{"id" => "kept", "enabled" => false}
           ]

    Req.Test.stub(ReqMock, &Req.Test.json(&1, %{models: []}))
    assert {:error, _} = Models.discover(opts)
  end
end
