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
    assert details.diff_stat == %{added: 1, removed: 1}
    assert loaded["diff_stat"] == %{"added" => 1, "removed" => 1}
  end

  test "preserves full diff_stat across ResultContract diff_lines truncation and 8KB details budget" do
    before_content = Enum.map_join(1..15, "\n", &"old #{&1}") <> "\n"
    after_content = Enum.map_join(1..120, "\n", &"new #{&1}") <> "\n"

    snapshot = ChangeSnapshot.build_edit_snapshot("/tmp/large.txt", before_content, after_content)
    assert snapshot.diff_stat == %{added: 120, removed: 15}
    assert length(snapshot.diff_lines) == 136

    details = Map.put(snapshot, :diff_lines, snapshot.diff_lines)
    projected = Handbean.Agent.Tool.ResultContract.project_details(details)

    assert length(projected.diff_lines) == 80
    assert projected.diff_stat == %{added: 120, removed: 15}

    huge_lines =
      Enum.map(1..80, fn idx ->
        %{"type" => "ins", "text" => String.duplicate("x", 150) <> "_#{idx}"}
      end)

    oversized_details = Map.put(details, :diff_lines, huge_lines)
    oversized_projected = Handbean.Agent.Tool.ResultContract.project_details(oversized_details)

    refute Map.has_key?(oversized_projected, :diff_lines)
    assert oversized_projected.diff_stat == %{added: 120, removed: 15}
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
