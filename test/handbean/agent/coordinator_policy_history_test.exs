defmodule Handbean.Agent.CoordinatorPolicyHistoryTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.Agent.CoordinatorTestSupport
  alias Handbean.Agent.CoordinatorTestSupport.NotifyProvider

  import Handbean.Agent.CoordinatorTestSupport

  setup context do
    CoordinatorTestSupport.setup_coordinator(context)
  end

  test "new runs include durable transcript history before the new prompt" do
    sid = "coord-history-#{System.unique_integer([:positive])}"

    assert {:ok, _conversation} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, _} =
             Handbean.ConversationTranscriptStore.append(sid, %{
               "id" => "old-user",
               "role" => "user",
               "content" => "Earlier user context",
               "delivery" => "steer",
               "interrupts_work" => true,
               "metadata" => %{"source" => "cli", "delivery" => "steer"}
             })

    assert {:ok, _} =
             Handbean.ConversationTranscriptStore.append(sid, %{
               "id" => "old-assistant",
               "role" => "assistant",
               "content" => "Earlier assistant answer"
             })

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "New prompt",
               opts(provider: NotifyProvider, provider_config: %{notify: self()})
             )

    assert_receive {:provider_messages, messages}

    assert Enum.map(messages, &{&1.role, &1.content}) == [
             {:user, "Earlier user context"},
             {:assistant, "Earlier assistant answer"},
             {:user, "New prompt"}
           ]

    Enum.each(messages, fn message ->
      assert %Handbean.Agent.Message{} = message
      refute Map.has_key?(Map.from_struct(message), :delivery)
      refute Map.has_key?(Map.from_struct(message), :interrupts_work)
      refute Map.has_key?(Map.from_struct(message), :metadata)
    end)

    assert_receive_run_end(sid)
  end

  test "removed observational memory model does not block an unrestricted workspace" do
    sid = "coord-stale-om-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(
                 om: %{
                   enabled: true,
                   model: "xai/grok-4.7"
                 }
               )
             )

    assert_receive_run_end(sid)
  end

  test "allowlisted workspace still rejects a catalog observational memory model" do
    sid = "coord-restricted-om-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbean.ConversationStore.create("default", id: sid)
    # The helper writes models.json inside the workspace and points
    # HANDBEAN_MODELS_FILE at it. Policy must live in a different directory,
    # otherwise saving the catalog overwrites the allowlist.
    workspace =
      Path.join(System.tmp_dir!(), "sigil_coord_allow_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    File.mkdir_p!(Path.dirname(Handbean.WorkspaceSettings.path(workspace)))

    File.write!(
      Handbean.WorkspaceSettings.path(workspace),
      ~s({"models":{"allow":{"providers":{"fake":{"models":["fake-model"]}}}}})
    )

    run_opts =
      opts(
        workspace_path: workspace,
        om: %{enabled: true, model: "other/other-model"}
      )
      |> Keyword.delete(:provider)

    # opts/1 writes a one-model catalog. Replace it after that call so the
    # rejected observer model is present, then excluded by the allowlist.
    File.write!(
      System.fetch_env!("HANDBEAN_MODELS_FILE"),
      ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"sk-fake","models":[{"id":"fake-model","name":"Fake Model"}]},"other":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"sk-other","models":[{"id":"other-model","name":"Other Model"}]}}})
    )

    assert {:error, reason} =
             Coordinator.add_message(
               sid,
               "hello",
               run_opts
             )

    assert reason =~ "other/other-model"
    File.rm_rf(workspace)
  end

  test "missing required opts return structured error" do
    sid = "coord-missing-#{System.unique_integer([:positive])}"

    assert {:error, {:missing_opts, missing}} = Coordinator.add_message(sid, "hello", [])
    assert :workspace_path in missing
    assert :model in missing
    assert :provider_config in missing
    assert :tools in missing
    assert :source in missing
  end

  # ── Workspace model policy enforcement ──

  describe "workspace model policy enforcement" do
    setup do
      old_models_file = System.get_env("HANDBEAN_MODELS_FILE")

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_coord_policy_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      # Write a global config with two providers / two models each
      File.write!(
        Path.join(tmp_dir, "models.json"),
        Jason.encode!(%{
          "defaultProvider" => "cloud-provider",
          "defaultModel" => "cloud-model-v1",
          "providers" => %{
            "cloud-provider" => %{
              "baseUrl" => "https://cloud.example.com/v1",
              "api" => "openai-chat-completions",
              "apiKey" => "sk-cloud",
              "models" => [
                %{"id" => "cloud-model-v1", "name" => "Cloud Model V1"},
                %{"id" => "cloud-model-v2", "name" => "Cloud Model V2"}
              ]
            },
            "local-llm" => %{
              "baseUrl" => "http://localhost:11434/v1",
              "api" => "openai-chat-completions",
              "apiKey" => "sk-local",
              "models" => [
                %{"id" => "qwen2.5-coder:7b", "name" => "Qwen 2.5 Coder 7B"}
              ]
            }
          }
        })
      )

      System.put_env("HANDBEAN_MODELS_FILE", Path.join(tmp_dir, "models.json"))

      on_exit(fn ->
        if old_models_file,
          do: System.put_env("HANDBEAN_MODELS_FILE", old_models_file),
          else: System.delete_env("HANDBEAN_MODELS_FILE")

        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    defp write_workspace_policy(workspace_root, policy) do
      settings_dir = Path.join(workspace_root, ".handbean")
      File.mkdir_p!(settings_dir)
      settings_path = Handbean.WorkspaceSettings.path(workspace_root)
      File.write!(settings_path, Jason.encode!(%{"models" => policy}))
      settings_path
    end

    defp restricted_opts(workspace_root, extra \\ []) do
      Keyword.merge(
        [
          workspace_path: workspace_root,
          model: "local-llm/qwen2.5-coder:7b",
          provider: Handbean.TestSupport.FakeProvider,
          provider_config: %{scenario: :simple_answer},
          tools: [],
          source: :cli,
          streaming: false,
          max_turns: 3
        ],
        extra
      )
    end

    test "add_message rejects disallowed model for restrictive workspace policy" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_restricted_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      write_workspace_policy(ws, %{
        "allow" => %{
          "providers" => %{
            "local-llm" => %{"models" => ["qwen2.5-coder:7b"]}
          }
        }
      })

      sid = "coord-policy-reject-#{System.unique_integer([:positive])}"

      # cloud-model-v1 is NOT in the allowlist
      assert {:error, reason} =
               Coordinator.add_message(
                 sid,
                 "hello",
                 restricted_opts(ws, model: "cloud-provider/cloud-model-v1")
               )

      assert reason =~ "not allowed"
    end

    test "add_message accepts allowed model for restrictive workspace policy" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_allow_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      write_workspace_policy(ws, %{
        "allow" => %{
          "providers" => %{
            "local-llm" => %{"models" => ["qwen2.5-coder:7b"]}
          }
        }
      })

      sid = "coord-policy-allow-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

      assert {:ok, %{action: :started}} =
               Coordinator.add_message(sid, "hello", restricted_opts(ws))

      assert_receive_run_end(sid)
    end

    test "add_message accepts any model when workspace has no policy file" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_none_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      sid = "coord-policy-none-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbean.ConversationStore.create("default", id: sid)

      assert {:ok, %{action: :started}} =
               Coordinator.add_message(
                 sid,
                 "hello",
                 restricted_opts(ws, model: "cloud-provider/cloud-model-v2")
               )

      assert_receive_run_end(sid)
    end
  end
end
