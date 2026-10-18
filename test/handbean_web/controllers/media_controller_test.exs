defmodule HandbeanWeb.MediaControllerTest do
  use HandbeanWeb.ConnCase, async: false

  alias Handbean.Media

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    root = Path.join(System.tmp_dir!(), "media-controller-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: root})
    {:ok, conversation} = Handbean.ConversationStore.create_free()

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbean, :host, previous_host),
        else: Application.delete_env(:handbean, :host)

      File.rm_rf!(root)
    end)

    %{root: root, conversation_id: conversation["id"]}
  end

  test "serves ready local media through the stable conversation URL with immutable headers", %{
    conn: conn,
    conversation_id: conversation_id
  } do
    assert {:ok, staged} =
             Media.stage(@png,
               conversation_id: conversation_id,
               producer_tool_call_id: "controller-tool",
               filename: "生成图.png"
             )

    assert {:ok, [ready]} =
             Media.mark_ready(
               conversation_id,
               "controller-tool",
               "msg-media-controller-tool",
               [staged.id]
             )

    path = "/media/#{conversation_id}/#{ready.id}/content"
    response_conn = get(conn, path)

    assert response(response_conn, 200) == @png
    assert get_resp_header(response_conn, "content-type") == ["image/png; charset=utf-8"]
    assert get_resp_header(response_conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(response_conn, "cache-control") == [
             "private, max-age=31536000, immutable"
           ]

    assert [disposition] = get_resp_header(response_conn, "content-disposition")
    assert disposition =~ "filename*=UTF-8''"
    refute disposition =~ "\r"
    refute disposition =~ "\n"

    assert [etag] = get_resp_header(response_conn, "etag")

    not_modified =
      conn
      |> recycle()
      |> put_req_header("if-none-match", etag)
      |> get(path)

    assert response(not_modified, 304) == ""
  end

  test "does not serve staged media or media through another conversation id", %{
    conn: conn,
    conversation_id: conversation_id
  } do
    assert {:ok, staged} =
             Media.stage(@png,
               conversation_id: conversation_id,
               producer_tool_call_id: "staged-tool",
               filename: "staged.png"
             )

    assert response(get(conn, "/media/#{conversation_id}/#{staged.id}/content"), 404) ==
             "Not Found"

    {:ok, other} = Handbean.ConversationStore.create_free()

    assert {:ok, [_ready]} =
             Media.mark_ready(
               conversation_id,
               "staged-tool",
               "msg-media-staged-tool",
               [staged.id]
             )

    assert response(get(recycle(conn), "/media/#{other["id"]}/#{staged.id}/content"), 404) ==
             "Not Found"
  end
end
