defmodule HandbeanProbe.Bridge.InboundTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.Bridge.Inbound
  alias HandbeanProbe.Bridge.Inbound.{EngineResult, Notification, PickedFile, Snapshot}

  describe "engine_result/1" do
    test "decodes the C atom-key envelope and the Kotlin JSON body" do
      assert {:ok, %EngineResult{} = wire} =
               Inbound.engine_result(%{
                 request_id: "rid-1",
                 generation: 3,
                 session_id: "s",
                 result: ~s({"snapshot_id":"snap","owner_request_id":"rid-1","outcome":"opened"}),
                 unknown_key: "dropped"
               })

      assert wire.request_id == "rid-1"
      assert wire.generation == 3
      assert wire.session_id == "s"
      assert {:ok, %{"snapshot_id" => "snap"}} = wire.body
      assert Inbound.outcome(wire.body) == "opened"

      assert %Snapshot{snapshot_id: "snap", owner_request_id: "rid-1"} =
               Inbound.snapshot(elem(wire.body, 1))
    end

    test "accepts the same keys as strings through the whitelist without String.to_atom" do
      assert {:ok, %EngineResult{request_id: "rid-2", generation: nil, body: {:error, "boom"}}} =
               Inbound.engine_result(%{"request_id" => "rid-2", "error" => "boom", "x" => 1})
    end

    test "body variants: cancelled, attachments batch, error document, invalid" do
      cancelled = fn result -> Inbound.engine_result(%{request_id: "r", result: result}) end

      assert {:ok, %EngineResult{body: :cancelled}} = cancelled.("cancelled")
      assert {:ok, %EngineResult{body: :cancelled}} = cancelled.(~s({"cancelled":true}))
      assert {:ok, %EngineResult{body: :cancelled}} = cancelled.(~s({"outcome":"cancelled"}))
      assert {:ok, %EngineResult{body: {:error, "denied"}}} = cancelled.(~s({"error":"denied"}))

      assert {:ok, %EngineResult{body: {:ok_batch, [%{"path" => "a"}], ["e1"]}}} =
               cancelled.(~s({"attachments":[{"path":"a"}],"errors":["e1"]}))

      assert {:ok, %EngineResult{body: {:error, :invalid_platform_result}}} =
               cancelled.("{not json")

      assert {:ok, %EngineResult{body: {:error, :invalid_platform_result}}} = cancelled.(nil)
    end

    test "a missing request id is invalid" do
      assert {:error, :invalid_engine_result} = Inbound.engine_result(%{generation: 1})
      assert {:error, {:invalid, :engine_result}} = Inbound.decode({:engine_result, %{}})
      assert {:error, {:invalid, :engine_result}} = Inbound.decode({:engine_result, "nope"})
    end
  end

  describe "decode/1" do
    test "lifts host shapes to structs and passes everything else through" do
      assert {:ok, {:engine_result, %EngineResult{request_id: "r"}}} =
               Inbound.decode({:engine_result, %{request_id: "r", result: "cancelled"}})

      assert {:ok, {:notification, %Notification{conversation_id: "c", workspace_id: "w"}}} =
               Inbound.decode(
                 {:notification,
                  %{
                    id: 1,
                    title: "t",
                    body: "b",
                    data: %{"conversation_id" => "c", workspace_id: "w"}
                  }}
               )

      assert {:ok, {:files, :picked, [%PickedFile{request_id: "imp", path: "/p", name: "n"}]}} =
               Inbound.decode(
                 {:files, :picked, [%{"request_id" => "imp", path: "/p", name: "n"}]}
               )

      assert {:ok, {:tap, :send}} = Inbound.decode({:tap, :send})

      assert {:ok, {:platform, :result, "r", :cancelled}} =
               Inbound.decode({:platform, :result, "r", :cancelled})
    end

    test "notification data that is not a map yields nil ids" do
      assert {:ok, {:notification, %Notification{conversation_id: nil, workspace_id: nil}}} =
               Inbound.decode({:notification, %{data: "junk"}})
    end
  end

  describe "snapshot/1 and outcome/1" do
    test "accepts string, atom and struct input and drops unknown keys" do
      snap = Inbound.snapshot(%{"snapshot_id" => "s", "size_bytes" => 3, "junk" => 1})
      assert %Snapshot{snapshot_id: "s", size_bytes: 3} = snap
      assert Inbound.snapshot(%{snapshot_id: "a"}).snapshot_id == "a"
      assert Inbound.snapshot(snap) == snap
      assert %Snapshot{snapshot_id: nil} = Inbound.snapshot(:nope)
    end

    test "outcome strings" do
      assert Inbound.outcome({:ok, %{"outcome" => "shared"}}) == "shared"
      assert Inbound.outcome({:ok, %{}}) == "outcome_unknown"
      assert Inbound.outcome({:error, "no_activity"}) == "no_activity"
      assert Inbound.outcome({:error, :timeout}) == "timeout"
      assert Inbound.outcome(:cancelled) == "cancelled_before_launch"
    end
  end
end
