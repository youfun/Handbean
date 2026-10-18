defmodule Handbean.ChangeSnapshotPersistenceTest do
  use ExUnit.Case, async: false

  alias Handbean.ChangeSnapshot

  test "persists full revert data behind a bounded opaque reference" do
    conversation_id = "snapshot-test-#{System.unique_integer([:positive])}"
    path = "/tmp/example.txt"
    snapshot = ChangeSnapshot.build_edit_snapshot(path, "before\n", "after\n")

    details = ChangeSnapshot.result_details(snapshot, %{conversation_id: conversation_id})

    refute Map.has_key?(details, :before_content)
    refute Map.has_key?(details, :after_content)
    assert details.reversible
    assert is_binary(details.change_snapshot_ref)

    assert {:ok, loaded} = ChangeSnapshot.load(details.change_snapshot_ref)
    assert loaded["before_content"] == "before\n"
    assert loaded["after_content"] == "after\n"
    assert loaded["change_id"] == snapshot.change_id
  end

  test "rejects path-unsafe conversation identifiers" do
    snapshot = ChangeSnapshot.build_write_snapshot("/tmp/example.txt", nil, "content")

    details = ChangeSnapshot.result_details(snapshot, %{conversation_id: "../escape"})

    assert details.reversible == false
    assert details.revert_status == "unavailable"
    assert details.revert_reason == "snapshot_unavailable"
    refute Map.has_key?(details, :change_snapshot_ref)
  end
end
