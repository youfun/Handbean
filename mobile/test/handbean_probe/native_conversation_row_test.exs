defmodule HandbeanProbe.NativeConversationRowTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeanProbe.Gettext

  alias HandbeanProbe.NativeConversationRow

  @conversation %{"id" => "conv-1", "title" => "Ship the row", "pinned_at" => nil}

  test "row shows the title and menu actions only while open" do
    idle = nodes(@conversation, selected?: false, running?: false, menu_open?: false)
    running = nodes(@conversation, selected?: false, running?: true, menu_open?: false)
    menu = nodes(@conversation, selected?: false, running?: false, menu_open?: true)

    pinned =
      nodes(Map.put(@conversation, "pinned_at", "2026-10-09T00:00:00Z"),
        selected?: false,
        running?: false,
        menu_open?: true
      )

    assert text?(idle, "Ship the row")
    refute menu_action?(idle)
    refute menu_action?(running)

    assert text?(menu, gettext("Pin"))
    assert text?(menu, gettext("Rename"))
    assert text?(menu, gettext("Copy ID"))
    assert text?(menu, gettext("Archive"))
    assert tap?(menu, {:toggle_pin_conversation, "conv-1"})
    assert tap?(menu, {:rename_conversation, "conv-1"})
    assert tap?(menu, {:copy_conversation_id, "conv-1"})
    assert tap?(menu, {:archive_conversation, "conv-1"})

    assert text?(pinned, gettext("Unpin"))
    refute text?(pinned, gettext("Pin"))

    card = NativeConversationRow.overflow_menu_card(@conversation)
    assert card.type == :column
    assert card.props[:fill_width] == false
    assert card.props[:id] == "conversation-menu-panel-conv-1"
  end

  test "rename field is shown only for the pending conversation" do
    pending = %{id: "conv-1", title: "Ship the row", error: "Name cannot be empty"}
    shown = nodes(@conversation, rename: pending)
    hidden = nodes(@conversation, rename: %{id: "other", title: "Elsewhere", error: nil})
    absent = nodes(@conversation, [])

    assert text?(shown, "Name cannot be empty")

    assert Enum.any?(
             flat(shown),
             &(&1.type == :text_field and &1.props[:value] == "Ship the row")
           )

    assert tap?(shown, {:confirm_rename_conversation, "Ship the row"})
    refute Enum.any?(flat(hidden), &(&1.type == :text_field))
    refute Enum.any?(flat(absent), &(&1.type == :text_field))
  end

  defp nodes(conversation, opts), do: NativeConversationRow.nodes(conversation, opts)

  defp flat(nodes), do: Enum.flat_map(nodes, &flatten/1)

  defp flatten(%{children: children} = node), do: [node | Enum.flat_map(children, &flatten/1)]
  defp flatten(node), do: [node]

  defp text?(nodes, text), do: Enum.any?(flat(nodes), &(&1.props[:text] == text))

  defp menu_action?(nodes) do
    Enum.any?(
      [
        gettext("Pin"),
        gettext("Unpin"),
        gettext("Rename"),
        gettext("Copy ID"),
        gettext("Archive")
      ],
      &text?(nodes, &1)
    )
  end

  defp tap?(nodes, tag) do
    Enum.any?(flat(nodes), fn node ->
      match?({_, ^tag}, node.props[:on_tap])
    end)
  end
end
