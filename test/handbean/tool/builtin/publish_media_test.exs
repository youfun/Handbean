defmodule Handbean.Tool.Builtin.PublishMediaTest do
  use Handbean.DataCase, async: false

  alias Handbean.Storage.ConversationMedia
  alias Handbean.Tool.Builtin.PublishMedia

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    root = Path.join(System.tmp_dir!(), "publish-media-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "data")
    File.mkdir_p!(workspace)
    File.mkdir_p!(data_dir)

    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: data_dir})

    {:ok, conversation} = Handbean.ConversationStore.create_free()

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, conversation_id: conversation["id"]}
  end

  test "publishes verified workspace media and returns only a public descriptor", context do
    path = Path.join(context.workspace, "generated.png")
    File.write!(path, @png)

    assert {:ok, message, %{published_media: [descriptor], side_effect: :committed}} =
             PublishMedia.execute(
               %{"path" => "generated.png"},
               %{
                 conversation_id: context.conversation_id,
                 tool_call_id: "publish-1",
                 working_directory: context.workspace
               }
             )

    assert message =~ "generated.png"
    assert descriptor.media_id
    assert descriptor.conversation_id == context.conversation_id
    assert descriptor.mime_type == "image/png"
    refute Map.has_key?(descriptor, :url)
    refute Map.has_key?(descriptor, :storage_key)

    media = Repo.get!(ConversationMedia, descriptor.media_id)
    assert media.status == "staged"
    assert media.producer_tool_call_id == "publish-1"
  end

  test "rejects sources outside the workspace and registered trusted roots", context do
    outside = Path.join(context.root, "outside.png")
    File.write!(outside, @png)

    assert {:error, reason, %{side_effect: :not_started}} =
             PublishMedia.execute(
               %{"path" => outside},
               %{
                 conversation_id: context.conversation_id,
                 tool_call_id: "publish-outside",
                 working_directory: context.workspace
               }
             )

    assert reason =~ "outside the allowed"
    refute Repo.get_by(ConversationMedia, producer_tool_call_id: "publish-outside")
  end

  test "public input projection never exposes an absolute path" do
    projected =
      PublishMedia.public_input(%{
        "path" => "/private/tmp/sensitive/generated.png",
        "filename" => "result.png"
      })

    assert projected == %{"path" => "generated.png", "filename" => "result.png"}
    refute inspect(projected) =~ "/private/tmp"
  end
end
