defmodule Handbean.E2E.PublishMediaTest do
  @moduledoc """
  Controlled end-to-end coverage for agent-published conversation media.

  Run: mix test --include e2e test/handbean/e2e/publish_media_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Coordinator
  alias Handbean.PubSub.Session
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e
  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbean.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbean.Repo, {:shared, self()})
    :ok
  end

  test "agent publishes an absolute workspace image without persisting its absolute path" do
    %{workspace: workspace} = E2EHarness.isolate_home!("publish-media")
    image_path = Path.join(workspace, "generated.png")
    File.write!(image_path, @png)

    {:ok, conversation} =
      Handbean.ConversationStore.create("media-ws", checkout_path: workspace)

    id = conversation["id"]
    :ok = Session.subscribe(id)
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    script = fn messages, _tools ->
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        "Image published"
      else
        {:tools,
         [
           %{
             name: "publish_media",
             input: %{"path" => image_path, "filename" => "result.png"}
           }
         ]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "Show me the generated image",
               workspace_path: workspace,
               working_directory: workspace,
               model: "fake-model",
               provider: Handbean.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: [Handbean.Tool.Builtin.PublishMedia],
               source: :cli,
               streaming: false
             )

    [{runner, _metadata}] = Registry.lookup(Handbean.AgentRunRegistry, id)
    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    entries = E2EHarness.transcript(id)
    tool = Enum.find(entries, &(&1["tool_name"] == "publish_media"))
    media_entry = Enum.find(entries, &(&1["id"] == "msg-media-#{tool["tool_use_id"]}"))

    assert tool["tool_status"] == "done"
    assert tool["input"]["path"] == "generated.png"
    refute Handbean.JSON.encode!(entries) =~ image_path

    assert media_entry["role"] == "assistant"
    assert [descriptor] = media_entry["attachments"]
    assert descriptor["filename"] == "result.png"
    refute Map.has_key?(descriptor, "url")
    refute Map.has_key?(descriptor, "storage_key")

    assert {:ok, media} = Handbean.Media.get_ready(id, descriptor["media_id"])
    assert {:ok, {:send_file, stored_path}} = Handbean.Media.delivery(media)
    assert File.read!(stored_path) == @png

    ref = Process.monitor(runner)
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
  end
end
