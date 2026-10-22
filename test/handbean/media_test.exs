defmodule Handbean.MediaTest do
  use Handbean.DataCase, async: false

  import Ecto.Query

  alias Handbean.Media
  alias Handbean.Media.Backends.Local
  alias Handbean.Repo
  alias Handbean.Security.PathValidator
  alias Handbean.Storage.ConversationMedia

  defmodule RedirectBackend do
    @behaviour Handbean.Media.Backend

    @impl true
    def put(_storage_key, _bytes, _metadata), do: :ok

    @impl true
    def delivery(storage_key, _metadata),
      do: {:ok, {:redirect, "https://media.invalid/#{storage_key}"}}

    @impl true
    def delete(_storage_key, _metadata), do: :ok
  end

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "handbean_media_#{System.unique_integer([:positive])}")

    workspace = Path.join(data_dir, "workspace")
    trusted_root = Path.join(data_dir, "trusted")
    File.mkdir_p!(workspace)
    File.mkdir_p!(trusted_root)

    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(Map.put(previous_host || %{}, :data_dir, data_dir))

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(data_dir)
    end)

    %{data_dir: data_dir, workspace: workspace, trusted_root: trusted_root}
  end

  test "local backend puts verified bytes, delivers a send_file, and deletes", %{
    data_dir: data_dir
  } do
    bytes = png()
    sha256 = sha256(bytes)
    key = "conversation-local/media-local.png"
    metadata = %{mime_type: "image/png", size_bytes: byte_size(bytes), sha256: sha256}

    assert :ok = Local.put(key, bytes, metadata)
    assert {:ok, {:send_file, path}} = Local.delivery(key, metadata)

    expected_path =
      data_dir
      |> Path.join(".handbean/media/conversation-local/media-local.png")
      |> PathValidator.resolve_symlink()

    assert path == expected_path

    assert File.read!(path) == bytes

    if match?({:unix, _}, :os.type()) do
      assert {:ok, %File.Stat{mode: file_mode}} = File.stat(path)
      assert Bitwise.band(file_mode, 0o777) == 0o600
      assert {:ok, %File.Stat{mode: dir_mode}} = File.stat(Path.dirname(path))
      assert Bitwise.band(dir_mode, 0o777) == 0o700
    end

    assert :ok = Local.delete(key, metadata)
    refute File.exists?(path)
    assert :ok = Local.delete(key, metadata)
  end

  test "local backend rejects Windows-path syntax, traversal, and symlink descendants", %{
    data_dir: data_dir
  } do
    metadata = metadata(png())

    for key <- [
          "conversation\\media.png",
          "C:/media.png",
          "../media.png",
          "conversation/../media.png",
          "conversation/C:\\media.png"
        ] do
      assert {:error, :invalid_storage_key} = Local.put(key, png(), metadata)
    end

    handbean_root = Path.join(data_dir, ".handbean")
    outside = Path.join(data_dir, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, handbean_root)

    assert {:error, {:unsafe_storage_descendant, :symlink}} =
             Local.put("conversation/media.png", png(), metadata)
  end

  test "stage_file enforces workspace and explicit trusted roots without a yolo exception", %{
    data_dir: data_dir,
    workspace: workspace,
    trusted_root: trusted_root
  } do
    conversation_id = create_conversation("media-file-auth")
    inside = write_png(workspace, "inside.png")
    trusted = write_png(trusted_root, "trusted.png")
    outside = write_png(data_dir, "outside.png")

    opts = [
      conversation_id: conversation_id,
      producer_tool_call_id: "tool-inside",
      working_directory: workspace,
      filename: "inside.png",
      yolo: true
    ]

    assert {:ok, %ConversationMedia{status: "staged"}} = Media.stage_file(inside, opts)

    assert {:error, :outside_trusted_root} =
             Media.stage_file(outside,
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-outside",
               working_directory: workspace,
               yolo: true
             )

    assert {:error, :missing_working_directory} =
             Media.stage_file("relative.png",
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-no-workspace"
             )

    disguised = write_png(workspace, "disguised.jpg")

    assert {:error, :type_mismatch} =
             Media.stage_file(disguised,
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-disguised",
               working_directory: workspace,
               filename: "renamed.png"
             )

    if match?({:unix, _}, :os.type()) do
      in_root_link = Path.join(workspace, "inside-link.png")
      File.ln_s!(inside, in_root_link)

      assert {:ok, %ConversationMedia{}} =
               Media.stage_file(in_root_link,
                 conversation_id: conversation_id,
                 producer_tool_call_id: "tool-in-root-link",
                 working_directory: workspace
               )

      outside_link = Path.join(workspace, "outside-link.png")
      File.ln_s!(outside, outside_link)

      assert {:error, :outside_trusted_root} =
               Media.stage_file(outside_link,
                 conversation_id: conversation_id,
                 producer_tool_call_id: "tool-outside-link",
                 working_directory: workspace
               )
    end

    sensitive_dir = Path.join(workspace, ".ssh")
    File.mkdir_p!(sensitive_dir)
    sensitive = write_png(sensitive_dir, "secret.png")

    assert {:error, :sensitive_media_source} =
             Media.stage_file(sensitive,
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-sensitive",
               working_directory: workspace
             )

    assert {:ok, %ConversationMedia{filename: "trusted.png"}} =
             Media.stage_file(trusted,
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-trusted",
               working_directory: workspace,
               trusted_roots: [trusted_root]
             )
  end

  test "staging is idempotent and public projection omits private storage fields" do
    conversation_id = create_conversation("media-idempotency")

    opts = [
      conversation_id: conversation_id,
      producer_tool_call_id: "tool-idempotent",
      filename: "result.png"
    ]

    assert {:ok, first} = Media.stage(png(), opts)
    assert {:ok, replay} = Media.stage(png(), opts)
    assert replay.id == first.id

    assert Repo.aggregate(
             from(media in ConversationMedia,
               where:
                 media.conversation_id == ^conversation_id and
                   media.producer_tool_call_id == "tool-idempotent"
             ),
             :count
           ) == 1

    descriptor = Media.project(first)

    assert descriptor == %{
             media_id: first.id,
             conversation_id: conversation_id,
             kind: "image",
             mime_type: "image/png",
             filename: "result.png",
             size_bytes: byte_size(png()),
             sha256: sha256(png()),
             source: "agent"
           }

    string_descriptor = Map.new(descriptor, fn {key, value} -> {to_string(key), value} end)

    assert Media.project(nil) == []
    assert Media.project(string_descriptor) == descriptor

    assert Media.project([
             descriptor,
             Map.put(descriptor, :kind, "video"),
             Map.put(string_descriptor, "storage_key", "private/key.png"),
             %{"media_id" => "incomplete"}
           ]) == [descriptor, descriptor]

    assert Media.project(Map.put(descriptor, :sha256, "invalid")) == nil

    assert Media.ids([
             first,
             descriptor,
             string_descriptor
           ]) == [
             first.id,
             first.id,
             first.id
           ]

    refute Map.has_key?(descriptor, :backend)
    refute Map.has_key?(descriptor, :storage_key)
    refute Map.has_key?(descriptor, :storage_path)
    refute Map.has_key?(descriptor, :path)
    refute Map.has_key?(descriptor, :url)
  end

  test "ready transition is transaction-safe and delivery uses each object's stored backend" do
    conversation_id = create_conversation("media-backend-switch")
    registry = %{"local" => Local, "redirect" => RedirectBackend}

    assert {:ok, local} =
             Media.stage(png(),
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-local",
               filename: "local.png",
               backend_registry: registry
             )

    assert {:ok, remote} =
             Media.stage(png(),
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-remote",
               filename: "remote.png",
               backend: "redirect",
               backend_registry: registry
             )

    assert {:ok, [ready_local]} =
             Repo.transaction(fn ->
               {:ok, ready} =
                 Media.mark_ready_in_tx(
                   conversation_id,
                   "tool-local",
                   "entry-local",
                   [local.id]
                 )

               ready
             end)

    assert ready_local.status == "ready"

    assert {:ok, [ready_remote]} =
             Media.mark_ready(conversation_id, "tool-remote", "entry-remote", [remote.id])

    assert {:ok, ^ready_local} = Media.get_ready(conversation_id, local.id)
    assert {:error, :not_found} = Media.get_ready("another-conversation", local.id)

    assert {:ok, {:send_file, local_path}} =
             Media.delivery(ready_local, backend_registry: registry)

    assert File.exists?(local_path)

    assert {:ok, {:redirect, redirect_url}} =
             Media.delivery(ready_remote, backend_registry: registry)

    assert redirect_url == "https://media.invalid/#{remote.storage_key}"

    assert {:ok, {:send_file, ^local_path}} =
             Media.delivery(ready_local,
               backend: "redirect",
               backend_registry: registry
             )
  end

  test "pending-delete transition is atomic and exposes GC candidates" do
    conversation_id = create_conversation("media-gc")

    assert {:ok, media} =
             Media.stage(png(),
               conversation_id: conversation_id,
               producer_tool_call_id: "tool-gc",
               filename: "gc.png"
             )

    assert {:error, :media_set_mismatch} =
             Media.mark_pending_delete(conversation_id, [media.id, "missing-media"])

    assert Repo.get!(ConversationMedia, media.id).status == "staged"
    assert {:ok, 1} = Media.mark_pending_delete(conversation_id, [media.id])

    assert Enum.any?(
             Media.gc_candidates("pending_delete", DateTime.add(DateTime.utc_now(), 1, :second)),
             &(&1.id == media.id)
           )

    pending = Repo.get!(ConversationMedia, media.id)
    assert :ok = Media.delete_pending(pending)
    refute Repo.get(ConversationMedia, media.id)
  end

  test "unknown persisted backend ids are never interpreted as modules" do
    media = %ConversationMedia{
      status: "ready",
      backend: "Elixir.System",
      storage_key: "conversation/media.png"
    }

    assert {:error, :unknown_backend} = Media.delivery(media)
  end

  defp create_conversation(id) do
    assert {:ok, conversation} = Handbean.ConversationStore.create_free(id: id)
    conversation["id"]
  end

  defp write_png(directory, filename) do
    path = Path.join(directory, filename)
    File.write!(path, png())
    path
  end

  defp png, do: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>

  defp metadata(bytes) do
    %{mime_type: "image/png", size_bytes: byte_size(bytes), sha256: sha256(bytes)}
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
