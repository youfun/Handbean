defmodule Handbean.E2E.SubscriptionProviderTest do
  @moduledoc """
  Saved Ollama Cloud and OpenCode Go subscriptions reach their cloud routes
  through Coordinator → Runner → the dedicated adapter.

  HTTP is stubbed. The adapter, model routing, and transcript persistence are
  real. A missing key must name the subscription env var and must not call
  the vendor.

  Run: mix test --include e2e test/handbean/e2e/subscription_provider_test.exs
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Handbean.Agent.Coordinator
  alias Handbean.Agent.ModelConfig
  alias Handbean.ConversationStore
  alias Handbean.ConversationTranscriptStore
  alias Handbean.PubSub.Session

  @moduletag :e2e

  setup :setup_home
  setup {Req.Test, :set_req_test_to_shared}

  defp setup_home(_) do
    root = Path.join(System.tmp_dir!(), "subscription-e2e-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "probe.txt"), "ORCHID-7741")
    File.mkdir_p!(Path.join(root, ".handbean"))

    old_home = System.get_env("HOME")
    old_models = System.get_env("HANDBEAN_MODELS_FILE")
    old_ollama = System.get_env("OLLAMA_API_KEY")
    old_go = System.get_env("OPENCODE_GO_API_KEY")

    System.put_env("HOME", root)
    System.put_env("HANDBEAN_MODELS_FILE", Path.join(root, ".handbean/models.json"))
    System.delete_env("OLLAMA_API_KEY")
    System.delete_env("OPENCODE_GO_API_KEY")

    on_exit(fn ->
      restore_env("HOME", old_home)
      restore_env("HANDBEAN_MODELS_FILE", old_models)
      restore_env("OLLAMA_API_KEY", old_ollama)
      restore_env("OPENCODE_GO_API_KEY", old_go)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "Ollama Cloud reads the saved catalog model and persists the tool answer", %{root: root} do
    save_subscription!("ollama", "env:OLLAMA_API_KEY")
    System.put_env("OLLAMA_API_KEY", "ollama-test-key")

    owner = self()

    Req.Test.stub(Handbean.E2E.OllamaCloud, fn conn ->
      {:ok, body, conn} = read_body(conn)
      decoded = Handbean.JSON.decode!(body)

      send(
        owner,
        {:ollama, Plug.Conn.request_url(conn), header(conn, "authorization"),
         header(conn, "user-agent"), decoded}
      )

      reply =
        if tool_result?(decoded) do
          chat_text("Read ORCHID-7741")
        else
          chat_tool("read-local", "read", ~s({"file_path":"probe.txt"}))
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, reply)
    end)

    sid = start_chat!(root, "ollama/gemma4:31b", plug: {Req.Test, Handbean.E2E.OllamaCloud})

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed, turns: 2}}},
                   5_000

    settle(sid)

    assert_received {:ollama, "https://ollama.com/v1/chat/completions", "Bearer ollama-test-key",
                     "Handbean/0.2.1", first}

    assert first["model"] == "gemma4:31b"
    assert_received {:ollama, "https://ollama.com/v1/chat/completions", _, _, _second}
    refute_received {:ollama, _, _, _, _}

    assert_persisted(sid, "Read ORCHID-7741")
  end

  test "OpenCode Go routes a saved Messages model and keeps the session header", %{root: root} do
    save_subscription!("opencode-go", "go-test-key")

    owner = self()

    Req.Test.stub(Handbean.E2E.OpenCodeGo, fn conn ->
      {:ok, body, conn} = read_body(conn)
      decoded = Handbean.JSON.decode!(body)
      send(owner, {:go, Plug.Conn.request_url(conn), conn.req_headers, decoded})

      reply =
        if Enum.any?(
             decoded["messages"] || [],
             &(&1["role"] == "user" and tool_result_message?(&1))
           ) do
          messages_text("Read ORCHID-7741")
        else
          messages_tool("read-local", "read", %{"file_path" => "probe.txt"})
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, reply)
    end)

    sid = start_chat!(root, "opencode-go/minimax-m3", plug: {Req.Test, Handbean.E2E.OpenCodeGo})

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed, turns: 2}}},
                   5_000

    settle(sid)

    assert_received {:go, "https://opencode.ai/zen/go/v1/messages", headers, body}
    assert {"authorization", "Bearer go-test-key"} in headers
    assert user_agents(headers) == ["Handbean/0.2.1"]
    assert {"x-opencode-session", sid} in headers
    refute Enum.any?(headers, &match?({"x-api-key", _}, &1))
    refute Enum.any?(headers, &match?({"x-opencode-session", session} when session != sid, &1))
    assert body["model"] == "minimax-m3"

    assert_persisted(sid, "Read ORCHID-7741")
  end

  test "a saved subscription without a key names that key and does not call the vendor", %{
    root: root
  } do
    save_subscription!("ollama", "")

    Req.Test.stub(Handbean.E2E.OllamaMissing, fn conn ->
      flunk("missing Ollama key must not request #{conn.request_path}")
    end)

    {:ok, conversation} = ConversationStore.create("subscription-workspace")
    sid = conversation["id"]
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "Read probe.txt",
               workspace_path: root,
               model: "ollama/gemma4:31b",
               provider_config: %{req_options: [plug: {Req.Test, Handbean.E2E.OllamaMissing}]},
               tools: [Handbean.Tool.Builtin.Read],
               middleware: [],
               source: :cli,
               streaming: false,
               max_turns: 2
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :error, error: error}}},
                   5_000

    settle(sid)
    assert error =~ "OLLAMA_API_KEY"

    {:ok, entries} = ConversationTranscriptStore.list(sid)

    assert Enum.any?(
             entries,
             &(&1["message_type"] == "error" and &1["content"] =~ "OLLAMA_API_KEY")
           )
  end

  defp save_subscription!(provider_id, api_key) do
    preset = Handbean.Agent.Provider.SubscriptionCatalog.preset(provider_id)

    attrs = Map.put(preset, "apiKey", api_key)

    assert :ok = ModelConfig.add_provider(provider_id, attrs)
  end

  defp start_chat!(root, model, plug: plug) do
    {:ok, conversation} = ConversationStore.create("subscription-workspace")
    sid = conversation["id"]
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "Read probe.txt",
               workspace_path: root,
               model: model,
               provider_config: %{req_options: [plug: plug]},
               tools: [Handbean.Tool.Builtin.Read],
               middleware: [],
               source: :cli,
               streaming: false,
               max_turns: 3
             )

    sid
  end

  defp assert_persisted(sid, answer) do
    {:ok, entries} = ConversationTranscriptStore.list(sid)
    assert [tool] = Enum.filter(entries, &(&1["content_type"] == "tool"))
    assert tool["tool_use_id"] == "read-local"
    assert tool["tool_status"] == "done"
    assert [assistant] = Enum.filter(entries, &(&1["role"] == "assistant"))
    assert assistant["content"] == answer
    refute Enum.any?(entries, &(&1["message_type"] == "error"))
  end

  defp tool_result?(decoded) do
    Enum.any?(decoded["messages"] || [], fn message ->
      message["role"] == "tool" or is_list(message["tool_calls"])
    end) and
      Enum.any?(decoded["messages"] || [], &(&1["role"] == "tool"))
  end

  defp tool_result_message?(%{"content" => blocks}) when is_list(blocks) do
    Enum.any?(blocks, &(&1["type"] == "tool_result"))
  end

  defp tool_result_message?(_), do: false

  defp chat_tool(id, name, arguments) do
    Handbean.JSON.encode!(%{
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => id,
                "type" => "function",
                "function" => %{"name" => name, "arguments" => arguments}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    })
  end

  defp chat_text(text) do
    Handbean.JSON.encode!(%{
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ]
    })
  end

  defp messages_tool(id, name, input) do
    Handbean.JSON.encode!(%{
      "id" => "msg_tool",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    })
  end

  defp messages_text(text) do
    Handbean.JSON.encode!(%{
      "id" => "msg_final",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    })
  end

  defp user_agents(headers) do
    for {name, value} <- headers, String.downcase(name) == "user-agent", do: value
  end

  defp header(conn, name) do
    conn
    |> get_req_header(name)
    |> List.first()
  end

  defp settle(sid) do
    for {pid, _} <- Registry.lookup(Handbean.AgentRunRegistry, sid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
