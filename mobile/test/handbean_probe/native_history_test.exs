defmodule HandbeanProbe.NativeHistoryTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeanProbe.Gettext
  alias HandbeanProbe.NativeHistory

  @now ~U[2026-09-10 12:00:00Z]
  @workspaces [%{"id" => "a", "name" => "Alpha"}, %{"id" => "b", "name" => "Beta"}]

  test "pinned, free, and workspace groups hide archived and unknown workspaces" do
    conversations = [
      conversation("a-new", "a", 0),
      conversation("b-new", "b", -60),
      conversation("old-a", "a", -80 * 3600),
      conversation("deleted", "gone", 0),
      Map.put(conversation("archived", "a", 0), "archived_at", "2026-09-10T12:00:00Z"),
      Map.merge(conversation("free-new", nil, -30), %{"scope" => "free"}),
      Map.merge(conversation("free-old", nil, -90 * 3600), %{"scope" => "free"}),
      conversation("pinned-free", nil, -10)
      |> Map.merge(%{"scope" => "free", "pinned_at" => "2026-09-10T11:00:00Z"}),
      Map.put(conversation("pinned-a", "a", -5), "pinned_at", "2026-09-10T12:00:00Z"),
      Map.put(conversation("pinned-archived", "b", 0), "pinned_at", "2026-09-10T12:30:00Z")
      |> Map.put("archived_at", "2026-09-10T12:00:00Z")
    ]

    history = NativeHistory.project(conversations, @workspaces, @now)

    assert Enum.map(history.pinned, & &1["id"]) == ["pinned-a", "pinned-free"]
    assert Enum.map(history.free, & &1["id"]) == ["free-new", "free-old"]
    assert Enum.map(history.workspaces, & &1.workspace["id"]) == ["a", "b"]

    alpha = Enum.find(history.workspaces, &(&1.workspace["id"] == "a"))
    beta = Enum.find(history.workspaces, &(&1.workspace["id"] == "b"))
    assert Enum.map(alpha.conversations, & &1["id"]) == ["a-new", "old-a"]
    assert Enum.map(beta.conversations, & &1["id"]) == ["b-new"]
    refute "pinned-a" in Enum.map(alpha.conversations, & &1["id"])
    refute "pinned-free" in Enum.map(history.free, & &1["id"])
  end

  test "missing timestamp stays in its workspace and empty workspaces remain" do
    history =
      NativeHistory.project(
        [%{"id" => "unknown", "workspace_id" => "b"}],
        @workspaces,
        @now
      )

    assert history.pinned == []
    assert history.free == []
    assert Enum.map(history.workspaces, & &1.workspace["id"]) == ["a", "b"]
    assert hd(history.workspaces).conversations == []
    beta = Enum.find(history.workspaces, &(&1.workspace["id"] == "b"))
    assert Enum.map(beta.conversations, & &1["id"]) == ["unknown"]
  end

  test "render shows pinned only when present, then free, then each workspace" do
    history = sample_history()
    rendered = NativeHistory.render(history, %{selected_id: "a-new"})

    assert texts(rendered) |> Enum.filter(&(&1 in [gettext("已置顶"), gettext("对话")])) == [
             gettext("已置顶"),
             gettext("对话")
           ]

    assert "Alpha" in texts(rendered)
    assert "Beta" in texts(rendered)
    refute texts(rendered) |> Enum.any?(&String.contains?(&1, "Inactive over 72 hours"))
    assert "2" in texts(rendered)
    assert "1" in texts(rendered)

    assert {:new_free_chat} in tags(rendered)
    assert {:new_workspace_conversation, "a"} in tags(rendered)
    assert {:new_workspace_conversation, "b"} in tags(rendered)
    assert {:toggle_history_group, "pinned"} in tags(rendered)
    assert {:toggle_history_group, "free"} in tags(rendered)
    assert {:toggle_history_group, "a"} in tags(rendered)

    assert "pinned-a" in texts(rendered)
    assert "free-old" in texts(rendered)
    assert "old-a" in texts(rendered)
    refute "archived" in texts(rendered)

    assert {:conversation, "a-new"} in tags(rendered)
  end

  test "collapsed groups keep headers and hide their conversations" do
    history = sample_history()

    rendered =
      NativeHistory.render(history, %{
        collapsed: MapSet.new(["pinned", "free", "a"]),
        running_ids: MapSet.new(["b-new"]),
        menu_id: "b-new"
      })

    assert gettext("已置顶") in texts(rendered)
    assert gettext("对话") in texts(rendered)
    assert "Alpha" in texts(rendered)
    refute "pinned-a" in texts(rendered)
    refute "free-new" in texts(rendered)
    refute "old-a" in texts(rendered)
    assert "b-new" in texts(rendered)
    assert {:new_free_chat} in tags(rendered)
  end

  test "no pinned header when nothing is pinned, and missing opts default open" do
    history = NativeHistory.project([], @workspaces, @now)
    rendered = NativeHistory.render(history, %{})

    refute gettext("已置顶") in texts(rendered)
    assert gettext("对话") in texts(rendered)
    assert "Alpha" in texts(rendered)
    assert "0" in texts(rendered)
    refute {:toggle_history_group, "pinned"} in tags(rendered)
    assert {:new_workspace_conversation, "b"} in tags(rendered)
  end

  defp sample_history do
    NativeHistory.project(
      [
        conversation("a-new", "a", 0),
        conversation("old-a", "a", -80 * 3600),
        conversation("b-new", "b", -60),
        Map.merge(conversation("free-new", nil, -30), %{"scope" => "free"}),
        Map.merge(conversation("free-old", nil, -90 * 3600), %{"scope" => "free"}),
        Map.put(conversation("pinned-a", "a", -5), "pinned_at", "2026-09-10T12:00:00Z"),
        conversation("pinned-free", nil, -10)
        |> Map.merge(%{"scope" => "free", "pinned_at" => "2026-09-10T11:00:00Z"}),
        Map.put(conversation("archived", "a", 0), "archived_at", "2026-09-10T12:00:00Z")
      ],
      @workspaces,
      @now
    )
  end

  defp conversation(id, workspace, offset) do
    %{
      "id" => id,
      "title" => id,
      "workspace_id" => workspace,
      "updated_at" => @now |> DateTime.add(offset) |> DateTime.to_iso8601()
    }
  end

  defp texts(nodes), do: collect(nodes, fn %{props: props} -> [props[:text]] end)

  defp tags(nodes) do
    collect(nodes, fn %{props: props} ->
      case props[:on_tap] do
        {_pid, tag} -> [tag]
        _ -> []
      end
    end)
  end

  defp collect(nodes, fun) do
    Enum.flat_map(nodes, fn
      %{children: children} = node ->
        Enum.reject(fun.(node), &is_nil/1) ++ collect(children, fun)

      _ ->
        []
    end)
  end
end
