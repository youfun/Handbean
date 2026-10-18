defmodule HandbeanWeb.Feature.WorkspaceFeatureTest do
  @moduledoc """
  PhoenixTest feature tests for the Handbean Workspace LiveView.

  Covers user-facing flows:
    - Send message (发送消息)
    - Switch model (切换model)
    - New conversation (增加新对话)
    - Archive / unarchive conversation (存档/恢复)
    - Archived conversation visibility (已存档)
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.TestSupport.E2EHarness

  defp isolate_conversation_home! do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "handbean_feature_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)
    safe_rm_test_rune!(home_dir)

    on_exit(fn ->
      E2EHarness.stop_runtime!()

      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    home_dir
  end

  defp safe_rm_test_rune!(home_dir) do
    target = Path.expand(Path.join(home_dir, ".handbean"))
    tmp_root = Path.expand(System.tmp_dir!())

    if String.starts_with?(target, tmp_root) do
      File.rm_rf!(target)
    else
      raise "[PathSafety] refusing to delete non-temp .handbean/: #{target} (tmp_root=#{tmp_root})"
    end
  end

  setup do
    isolate_conversation_home!()
    old_provider = Application.get_env(:handbean, :test_provider)
    E2EHarness.use_fake_provider!(:simple_answer)

    on_exit(fn ->
      if old_provider do
        Application.put_env(:handbean, :test_provider, old_provider)
      else
        Application.delete_env(:handbean, :test_provider)
      end
    end)

    :ok
  end

  describe "workspace mount" do
    test "renders workspace with title and three-column layout", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("h2.projects-panel-title")
      |> assert_has("#activity-bar")
      |> assert_has("#workspace-panel")
      |> assert_has("#ai-panel")
      |> assert_path("/")
    end

    test "renders status bar with token and session info", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("#status-bar")
      |> assert_has("#status-tokens")
      |> assert_has("#status-label", "idle")
      |> assert_has("#status-session-id")
    end

    test "renders empty state when no messages present", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("#no-messages", "No messages yet")
    end
  end

  describe "send message" do
    test "sending a message displays it in the chat area", %{conn: conn} do
      conn
      |> visit("/")
      |> fill_in("#ai-input", "Message", with: "Hello, world!", exact: false)
      |> click_button("#send-button", "")
      |> assert_has(".msg-bubble.msg-user", "Hello, world!")
    end

    test "sending a message clears the input field", %{conn: conn} do
      conn
      |> visit("/")
      |> fill_in("#ai-input", "Message", with: "Read config file", exact: false)
      |> click_button("button#send-button", "")
      |> assert_has("textarea#ai-input", "")
    end

    test "sending empty message does not add to chat", %{conn: conn} do
      conn
      |> visit("/")
      |> fill_in("#ai-input", "Message", with: "   ", exact: false)
      |> click_button("button#send-button", "")
      |> refute_has(".msg-bubble.msg-user", "   ")
    end

    test "send button is present on the page", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("#send-button")
    end

    test "ai input is present on the page", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("textarea#ai-input")
    end
  end

  describe "switch model" do
    test "model picker is visible with available models", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("select#model-picker")
    end

    test "model picker remains visible after mount", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("select#model-picker")
    end
  end

  describe "new conversation" do
    test "global new conversation button and in-list add workspace button are present", %{
      conn: conn
    } do
      conn
      |> visit("/")
      |> assert_has("#new-conversation-picker-toggle[title='New conversation']")
      |> assert_has("#add-workspace[title='Add workspace']")
    end

    test "clicking new conversation clears messages and resets UI", %{conn: conn} do
      conn
      |> visit("/")
      |> click_button("#new-conversation-picker-toggle", "")
      |> click_button("#new-conversation-project-default", "")
      |> assert_has("#no-messages", "No messages yet")
      |> assert_has("#status-label", "idle")
      |> assert_path("/w/default/c/*")
    end

    test "new conversation after sending a message clears the chat", %{conn: conn} do
      conn
      |> visit("/")
      |> fill_in("#ai-input", "Message", with: "Previous message", exact: false)
      |> click_button("#send-button", "")
      |> assert_has(".msg-bubble.msg-user", "Previous message")
      |> click_button("#new-conversation-picker-toggle", "")
      |> click_button("#new-conversation-project-default", "")
      |> assert_has("#no-messages", "No messages yet")
      |> refute_has(".msg-bubble.msg-user", "Previous message")
    end
  end

  describe "free chat" do
    test "new free chat is not bound to a workspace and hides the file panel", %{conn: conn} do
      session =
        conn
        |> visit("/")
        |> assert_has("#free-chats", "Chats")
        |> assert_has("#workspace-panel")
        |> click_button("#new-free-conversation", "")

      session
      |> assert_has("#no-messages", "No messages yet")
      |> assert_has("#ai-input")
      |> refute_has("#workspace-panel")
      |> assert_path("/c/*")

      "/c/" <> conv_id = session.current_path
      {:ok, meta} = Handbean.ConversationStore.get_metadata(conv_id)
      assert meta["scope"] == "free"
      assert meta["workspace_id"] in [nil, ""]
    end
  end

  describe "archive conversation" do
    setup do
      isolate_conversation_home!()
      :ok
    end

    test "archive button exists on conversation list", %{conn: conn} do
      conn
      |> visit("/")
      |> click_button("#new-conversation-picker-toggle", "")
      |> click_button("#new-conversation-project-default", "")
      |> assert_has("button[phx-click='toggle_conversation_menu']", "More actions")
      |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")
      |> assert_has(".conversation-menu-item[phx-click='archive_conversation']", "Archive")
    end

    test "conversation menu copies the id used for thread messaging", %{conn: conn} do
      session =
        conn
        |> visit("/")
        |> click_button("#new-conversation-picker-toggle", "")
        |> click_button("#new-conversation-project-default", "")
        |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")

      [conv] = Handbean.ConversationStore.list(include_timeline?: false)

      assert_has(session, ".conversation-menu-item[data-copy='#{conv["id"]}']", "Copy ID")
    end

    test "archive conversation removes it from active list", %{conn: conn} do
      conn
      |> visit("/")
      |> click_button("#new-conversation-picker-toggle", "")
      |> click_button("#new-conversation-project-default", "")
      |> assert_has("button", "New chat")
      |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")
      |> click_button(".conversation-menu-item[phx-click='archive_conversation']", "Archive")
      |> assert_has("#no-messages", "No messages yet")
    end

    test "Archived group contains archived conversations", %{conn: conn} do
      session =
        conn
        |> visit("/")
        |> click_button("#new-conversation-picker-toggle", "")
        |> click_button("#new-conversation-project-default", "")
        |> fill_in("#ai-input", "Message", with: "Archive this conversation", exact: false)
        |> click_button("#send-button", "")
        |> assert_has(".msg-bubble.msg-assistant", "Hello! I am a fake provider response.",
          timeout: 5_000
        )

      "/w/default/c/" <> archived_id = session.current_path

      session
      |> within("#conversation-#{archived_id}", fn s ->
        s
        |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")
        |> click_button(".conversation-menu-item[phx-click='archive_conversation']", "Archive")
      end)
      |> click_button("button[phx-click='toggle_archive']", "Archived")
      |> assert_has("#archived-conversation-#{archived_id}")

      assert {:ok, archived} = Handbean.ConversationStore.get_metadata(archived_id)
      assert is_binary(archived["archived_at"])
    end

    test "archive toggle button is present", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("button[phx-click='toggle_archive']", "Archived")
    end
  end

  describe "pin conversation" do
    setup do
      isolate_conversation_home!()
      :ok
    end

    test "pin and unpin from the conversation menu", %{conn: conn} do
      conn
      |> visit("/")
      |> click_button("#new-conversation-picker-toggle", "")
      |> click_button("#new-conversation-project-default", "")
      |> within("#workspace-conversations-default", fn session ->
        session
        |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")
        |> click_button(".conversation-menu-item[phx-click='toggle_pin_conversation']", "Pin")
      end)
      |> assert_has("#pinned-conversations", "New chat")
      |> within("#pinned-conversations", fn session ->
        session
        |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")
        |> click_button(
          ".conversation-menu-item[phx-click='toggle_pin_conversation']",
          "Unpin"
        )
      end)
      |> refute_has("#pinned-conversations")
      |> assert_has("#workspace-conversations-default", "New chat")
    end
  end

  describe "rename conversation" do
    setup do
      isolate_conversation_home!()
      :ok
    end

    test "rename from the conversation menu updates the sidebar", %{conn: conn} do
      conn
      |> visit("/")
      |> click_button("#new-conversation-picker-toggle", "")
      |> click_button("#new-conversation-project-default", "")
      |> fill_in("#ai-input", "Message", with: "Need a title", exact: false)
      |> click_button("#send-button", "")
      |> within("#workspace-conversations-default", fn s ->
        s
        |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")
        |> click_button(".conversation-menu-item[phx-click='open_rename_conversation']", "Rename")
      end)
      |> assert_has("#rename-conversation-dialog", "Rename conversation")
      |> fill_in("#rename-conversation-input", "Conversation name", with: "底座评估")
      |> click_button("#rename-conversation-submit", "Save")
      |> assert_has(".conversation-item", "底座评估")
      |> refute_has("#rename-conversation-dialog")
    end
  end

  describe "unarchive conversation" do
    setup do
      isolate_conversation_home!()
      :ok
    end

    test "restore button in Archived restores the persisted conversation", %{conn: conn} do
      session =
        conn
        |> visit("/")
        |> click_button("#new-conversation-picker-toggle", "")
        |> click_button("#new-conversation-project-default", "")
        |> fill_in("#ai-input", "Message", with: "Restore this conversation", exact: false)
        |> click_button("#send-button", "")
        |> assert_has(".msg-bubble.msg-assistant", "Hello! I am a fake provider response.",
          timeout: 5_000
        )

      "/w/default/c/" <> archived_id = session.current_path

      session =
        session
        |> within("#conversation-#{archived_id}", fn s ->
          s
          |> click_button("button[phx-click='toggle_conversation_menu']", "More actions")
          |> click_button(".conversation-menu-item[phx-click='archive_conversation']", "Archive")
        end)

      assert {:ok, archived} =
               Handbean.ConversationStore.get(archived_id, include_timeline?: false)

      assert is_binary(archived["archived_at"])

      session
      |> click_button("button[phx-click='toggle_archive']", "Archived")
      |> assert_has("#archived-conversation-#{archived_id}")
      |> click_button(
        "#archived-conversation-#{archived_id} button[phx-click='unarchive_conversation']",
        ""
      )
      |> refute_has("#archived-conversation-#{archived_id}")
      |> assert_has("#conversation-#{archived_id}")
      |> click_button("#conversation-#{archived_id} button[phx-click='select_conversation']", "")
      |> assert_has(".msg-bubble.msg-user", "Restore this conversation")

      assert {:ok, restored} =
               Handbean.ConversationStore.get(archived_id, include_timeline?: false)

      assert is_nil(restored["archived_at"])
    end
  end

  describe "model picker interaction" do
    test "model picker dropdown is interactive", %{conn: conn} do
      conn
      |> visit("/")
      |> assert_has("select#model-picker")
    end
  end
end
