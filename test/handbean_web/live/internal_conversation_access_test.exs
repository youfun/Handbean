defmodule HandbeanWeb.InternalConversationAccessTest do
  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session

  setup do
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "internal-access-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    :ok
  end

  for {event, workspace_key} <- [
        {"select_conversation", "ws_id"},
        {"select_archived_conversation", "ws"}
      ] do
    test "#{event} rejects internal snapshots, missing IDs and workspace mismatches", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/")
      initial = :sys.get_state(view.pid).socket.assigns.current_conversation_id
      {:ok, child} = ConversationStore.create("default", visibility: "internal")
      id = child["id"]
      if unquote(event) == "select_archived_conversation", do: ConversationStore.archive(id)
      {:ok, _} = Session.start_or_get(session_id: id)
      queue = start_supervised!({Handbean.Agent.CandidateQueue, []})
      :ok = Session.attach_run(id, self(), queue, run_id: "private-run")
      :ok = Session.broadcast_event(id, :run_start, %{model: "fake"})
      :ok = Session.broadcast_event(id, :message_delta, %{chunk: "INTERNAL_PROBE_SECRET"})
      _ = Session.snapshot(id)
      assert {:error, :not_found} = ConversationStore.get(id)
      {:ok, other} = ConversationStore.create("different-workspace")

      for forbidden <- [id, "missing-conversation", other["id"]] do
        html =
          render_click(view, unquote(event), %{
            "id" => forbidden,
            unquote(workspace_key) => "default"
          })

        refute html =~ "INTERNAL_PROBE_SECRET"
        assert :sys.get_state(view.pid).socket.assigns.current_conversation_id == initial
        refute :sys.get_state(view.pid).socket.assigns[:session_id] == id
      end
    end

    test "#{event} still selects a visible conversation", %{conn: conn} do
      {:ok, conversation} = ConversationStore.create("default", [{"title", "Visible review"}])
      id = conversation["id"]
      if unquote(event) == "select_archived_conversation", do: ConversationStore.archive(id)
      {:ok, view, _} = live(conn, "/")

      render_click(view, unquote(event), %{"id" => id, unquote(workspace_key) => "default"})

      assert :sys.get_state(view.pid).socket.assigns.current_conversation_id == id
      assert_patch(view, "/w/default/c/#{id}")
    end
  end
end
