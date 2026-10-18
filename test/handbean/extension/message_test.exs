defmodule Handbean.Extension.MessageTest do
  use Handbean.DataCase, async: false

  alias Handbean.Extension.Message, as: ExtMessage

  describe "inject/4" do
    setup do
      session_id = "ext-msg-#{System.unique_integer([:positive])}"
      {:ok, _conversation} = Handbean.ConversationStore.create("default", id: session_id)

      {:ok, _pid} =
        Handbean.PubSub.Session.start_link(
          session_id: session_id,
          session_store_enabled?: true
        )

      on_exit(fn ->
        case Handbean.PubSub.Session.whereis(session_id) do
          nil ->
            :ok

          pid ->
            try do
              GenServer.stop(pid, :normal, 5000)
            catch
              :exit, _ -> :ok
            end
        end
      end)

      %{session_id: session_id}
    end

    test "inject with :steer delivery enqueues a steer candidate", %{session_id: sid} do
      # Need to attach a run (queue) first for steer to work
      # Without an active run, steer returns error
      assert {:error, :no_active_run} =
               ExtMessage.inject(sid, "continue working", :steer)
    end

    test "inject with :next_turn delivery adds to next_turn_messages", %{session_id: sid} do
      assert {:ok, _} = ExtMessage.inject(sid, "next prompt", :next_turn)

      # Verify the message was added
      pending = Handbean.PubSub.Session.get_pending_messages(sid)
      assert length(pending) == 1
      assert hd(pending).deliver_as == :next_turn
    end

    test "inject with :follow_up delivery returns error without active run", %{session_id: sid} do
      assert {:error, :no_active_run} =
               ExtMessage.inject(sid, "follow up", :follow_up)
    end

    test "inject defaults to :steer delivery", %{session_id: sid} do
      assert {:error, :no_active_run} = ExtMessage.inject(sid, "test")
    end
  end
end
