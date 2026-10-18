defmodule HandbeanProbe.NativeComposerTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeanProbe.Gettext

  alias HandbeanProbe.NativeComposer

  @tiny_png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
              1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248,
              207, 192, 240, 31, 0, 5, 0, 1, 253, 46, 43, 34, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66,
              96, 130>>

  test "empty composer is field plus add and send only" do
    tree = NativeComposer.render_field(%{draft: "", pending_attachments: []}, false)
    assert tree.type == :column
    assert Enum.reject(tree.children, &is_nil/1) |> length() == 1
    [row] = Enum.reject(tree.children, &is_nil/1)
    types = Enum.map(row.children, & &1.type)
    assert types == [:text_field, :icon, :icon]
    refute inspect(tree) =~ "local_only"
  end

  test "non-image attachments stay name and remove chips" do
    att = %{
      "id" => "t1",
      "filename" => "note.ex",
      "mime_type" => "text/x-source",
      "kind" => "text"
    }

    tree = NativeComposer.render_field(%{draft: "", pending_attachments: [att]}, false)
    encoded = inspect(tree)
    assert encoded =~ "note.ex"
    assert encoded =~ gettext("Remove")
    refute encoded =~ "local_only"
    assert match_image_nodes(tree) == []
  end

  test "images render local thumbs without bytes and preview stays closed" do
    path = write_png!()

    att = %{
      "id" => "img-1",
      "filename" => "shot.png",
      "mime_type" => "image/png",
      "kind" => "image",
      "controlled_path" => path
    }

    tree =
      NativeComposer.render_field(
        %{draft: "hi", pending_attachments: [att], composer_open_id: nil},
        false
      )

    encoded = inspect(tree)
    refute encoded =~ Base.encode64(@tiny_png)
    refute encoded =~ "data:image"
    refute encoded =~ "https://"
    images = match_image_nodes(tree)
    assert length(images) == 1
    [thumb] = images
    assert thumb.props.local_only == true
    assert thumb.props.src == path
    assert thumb.props.content_description == gettext("Image %{name}", name: "shot.png")
    assert thumb.props.fallback == gettext("Image cannot be displayed")
    refute encoded =~ "image/png"
  end

  test "preview card keeps the image metadata and remove action" do
    path = write_png!()

    att = %{
      "id" => "img-2",
      "filename" => "share.jpg",
      "mime_type" => "image/jpeg",
      "controlled_path" => path
    }

    tree =
      NativeComposer.render_field(
        %{draft: "", pending_attachments: [att], composer_open_id: "img-2"},
        false
      )

    encoded = inspect(tree)
    assert encoded =~ "share.jpg"
    assert encoded =~ "image/jpeg"
    assert encoded =~ gettext("Remove")
    assert encoded =~ gettext("Close")
    refute encoded =~ Base.encode64(@tiny_png)
    images = match_image_nodes(tree)
    assert length(images) == 2
    assert Enum.any?(images, &(&1.props.max_decode_edge == 240))
    assert Enum.all?(images, &(&1.props.local_only == true and &1.props.src == path))
  end

  test "missing or remote paths still emit fallback image nodes" do
    att = %{
      "id" => "gone",
      "filename" => "lost.png",
      "mime_type" => "image/png",
      "controlled_path" => "https://evil.example/a.png"
    }

    refute NativeComposer.local_file_src?(att["controlled_path"])
    tree = NativeComposer.render_field(%{draft: "", pending_attachments: [att]}, false)
    [thumb] = match_image_nodes(tree)
    assert thumb.props.src == ""
    assert thumb.props.local_only == true
    assert thumb.props.fallback == gettext("Image cannot be displayed")
  end

  defp match_image_nodes(node), do: collect_images(node, [])

  defp collect_images(%{type: :image} = node, acc), do: [node | acc]

  defp collect_images(%{children: children}, acc) when is_list(children) do
    Enum.reduce(children, acc, &collect_images/2)
  end

  defp collect_images(_, acc), do: acc

  defp write_png! do
    path =
      Path.join(System.tmp_dir!(), "composer_thumb_#{System.unique_integer([:positive])}.png")

    File.write!(path, @tiny_png)
    path
  end
end
