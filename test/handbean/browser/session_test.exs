defmodule Handbean.Browser.SessionTest do
  @moduledoc """
  Tests for conversation-scoped browser session ownership.

  The session process owns the managed session name and rotation.
  It does not own Chromium; quit is issued through an injected closer.
  """

  use ExUnit.Case, async: false

  alias Handbean.Browser.{Registry, Session, Supervisor}

  setup_all do
    unless Process.whereis(Registry) do
      {:ok, _} = Registry.start_link()
    end

    unless Process.whereis(Supervisor) do
      {:ok, _} = Supervisor.start_link()
    end

    :ok
  end

  setup do
    conversation_id = "conv-#{System.unique_integer([:positive])}"
    on_exit(fn -> Supervisor.stop_session(conversation_id) end)
    %{conversation_id: conversation_id}
  end

  describe "ensure/3" do
    test "creates then reuses the managed session name", %{conversation_id: conversation_id} do
      assert {:ok, first} = Session.ensure(conversation_id, "auto")
      assert first.outcome == :created
      assert is_binary(first.name)
      assert String.length(first.name) <= 12

      assert {:ok, second} = Session.ensure(conversation_id, "auto")
      assert second.outcome == :reused
      assert second.name == first.name
    end

    test "fresh rotates the name and closes the previous session", %{
      conversation_id: conversation_id
    } do
      test_pid = self()

      closer = fn name ->
        send(test_pid, {:closed, name})
        :ok
      end

      {:ok, first} = Session.ensure(conversation_id, "auto", closer: closer)
      {:ok, rotated} = Session.ensure(conversation_id, "fresh", closer: closer)

      assert rotated.outcome == :replaced
      assert rotated.name != first.name
      assert_received {:closed, closed_name}
      assert closed_name == first.name
    end

    test "sessions for different conversations stay isolated", %{conversation_id: conversation_id} do
      other = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Supervisor.stop_session(other) end)

      {:ok, a} = Session.ensure(conversation_id, "auto")
      {:ok, b} = Session.ensure(other, "auto")
      assert a.name != b.name
    end
  end

  describe "Registry" do
    test "looks up the live session pid", %{conversation_id: conversation_id} do
      {:ok, _} = Session.ensure(conversation_id, "auto")
      assert {:ok, pid} = Registry.lookup(conversation_id, "default")
      assert Process.alive?(pid)
    end
  end
end
