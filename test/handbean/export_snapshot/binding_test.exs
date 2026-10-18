defmodule Handbean.ExportSnapshot.BindingTest do
  use ExUnit.Case, async: false

  alias Handbean.ExportSnapshot.Binding

  setup do
    unless Process.whereis(Binding) do
      {:ok, _} = Binding.start_link([])
    end

    :ok
  end

  test "supervised owner keeps the table after a caller exits" do
    owner = Process.whereis(Binding)
    assert is_pid(owner)
    assert Process.alive?(owner)

    task =
      Task.async(fn ->
        Binding.put("c-owner", "t-owner", %{
          snapshot_id: "s",
          relative_path: "a.txt",
          workspace_path: "/tmp/ws",
          action: :open_file
        })
      end)

    Task.await(task)
    assert Process.alive?(owner)
    assert {:ok, %{snapshot_id: "s"}} = Binding.fetch("c-owner", "t-owner")
  end

  test "stores one snapshot per tool call and consume is atomic" do
    Binding.put("c1", "t1", %{
      snapshot_id: "a",
      relative_path: "a.txt",
      workspace_path: "/tmp/ws",
      action: :open_file,
      owner_request_id: "o"
    })

    assert {:ok, %{snapshot_id: "a"}} = Binding.fetch("c1", "t1")

    assert {:ok, %{snapshot_id: "a"}} =
             Binding.consume("c1", "t1", %{
               relative_path: "a.txt",
               workspace_path: "/tmp/ws",
               action: :open_file
             })

    assert :error = Binding.fetch("c1", "t1")
    assert {:error, :file_unavailable} = Binding.consume("c1", "t1", %{})
  end

  test "consume mismatch does not restore the row" do
    Binding.put("c2", "t2", %{
      snapshot_id: "b",
      relative_path: "ok.txt",
      workspace_path: "/tmp/ws",
      action: :share_file
    })

    assert {:error, :snapshot_mismatch} =
             Binding.consume("c2", "t2", %{
               relative_path: "other.txt",
               workspace_path: "/tmp/ws",
               action: :share_file
             })

    assert :error = Binding.fetch("c2", "t2")
  end
end
