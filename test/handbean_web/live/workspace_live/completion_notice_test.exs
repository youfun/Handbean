defmodule HandbeanWeb.WorkspaceLive.CompletionNoticeTest do
  use HandbeanWeb.WorkspaceLiveCase

  alias Handbean.Runtime.NotifyAdapter
  alias Handbean.Runtime.TaskTracker

  test "background completions link to free and workspace conversations on both pages", %{
    conn: conn
  } do
    previous_adapter = Application.fetch_env(:handbean, :runtime_notify_adapter)
    Application.put_env(:handbean, :runtime_notify_adapter, NotifyAdapter.Noop)
    TaskTracker.reset()

    on_exit(fn ->
      TaskTracker.reset()

      case previous_adapter do
        {:ok, adapter} -> Application.put_env(:handbean, :runtime_notify_adapter, adapter)
        :error -> Application.delete_env(:handbean, :runtime_notify_adapter)
      end
    end)

    {:ok, free} = Handbean.ConversationStore.create_free(title: "Free background task")
    {:ok, workspace_view, _html} = live(conn, "/")
    {:ok, settings_view, _html} = live(conn, "/settings")
    tracker = Process.whereis(TaskTracker)
    free_id = free["id"]

    send(tracker, {:run_lifecycle, free_id, :run_start, %{run_id: "free-notice"}})
    assert [%{conversation_id: ^free_id, scope: "free"}] = TaskTracker.snapshot().tasks

    send(
      tracker,
      {:run_lifecycle, free_id, :run_end, %{run_id: "free-notice", status: "completed"}}
    )

    assert TaskTracker.snapshot().tasks == []

    for {view, action} <- [{workspace_view, "patch"}, {settings_view, "navigate"}] do
      html = render(view)
      assert html =~ "Free background task"
      assert html =~ ~s(href="/c/#{free_id}")
      assert html =~ ~s(phx-click="[[&quot;#{action}&quot;)
    end

    task = %{
      conversation_id: "workspace-notice",
      workspace_id: "default",
      scope: "workspace",
      title: "Workspace background task"
    }

    for {view, action} <- [{workspace_view, "patch"}, {settings_view, "navigate"}] do
      send(view.pid, {:in_app_ended, task, :completed})
      :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Workspace background task"
      assert html =~ ~s(href="/w/default/c/workspace-notice")
      assert html =~ ~s(phx-click="[[&quot;#{action}&quot;)
    end
  end

  test "a completion without known scope is readable without a link", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    task = %{conversation_id: "missing", workspace_id: nil, scope: nil, title: "Unknown task"}

    send(view.pid, {:in_app_ended, task, :completed})
    :sys.get_state(view.pid)
    html = render(view)

    assert html =~ "Unknown task"
    refute html =~ ~s(href="/c/missing")
    assert Process.alive?(view.pid)
  end
end
