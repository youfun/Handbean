defmodule HandbeanWeb.WorkspaceLive.ScheduleCenterTest do
  @moduledoc """
  Task center behavior: ordering, filtering, selection, and the cost of a
  closed center. Selectors stay semantic (ids, roles, visible text) rather
  than pinning layout.
  """

  use HandbeanWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Handbean.Schedule.Store

  @zone "Asia/Shanghai"

  defp create_conversation(title) do
    {:ok, conversation} = Handbean.ConversationStore.create("default", title: title)
    conversation
  end

  defp create_weekly(name, opts \\ []) do
    conversation = create_conversation("#{name} 对话")

    {:ok, schedule} =
      Store.create(%{
        workspace_id: "default",
        conversation_id: conversation["id"],
        name: name,
        instruction: Keyword.get(opts, :instruction, "汇报编译结果"),
        time_zone: @zone,
        model: "fake/model",
        rule: %{"kind" => "weekly", "weekdays" => [1], "times" => ["09:00"]}
      })

    schedule
  end

  defp create_once(name) do
    conversation = create_conversation("#{name} 对话")

    {:ok, schedule} =
      Store.create(%{
        workspace_id: "default",
        conversation_id: conversation["id"],
        name: name,
        instruction: "只跑一次",
        time_zone: @zone,
        model: "fake/model",
        rule: %{
          "kind" => "once",
          "label" => "一小时后，只一次",
          "at" => Handbean.Schedule.now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
        }
      })

    schedule
  end

  defp run_and_finish(schedule, status) do
    {:ok, claim} = Store.claim(schedule, schedule.next_run_at)
    {:ok, _} = Store.finish_run(claim.run, status)
    Store.get(schedule.id)
  end

  defp open_center(conn, conversation_id) do
    {:ok, view, _html} = live(conn, "/w/default/c/#{conversation_id}")
    view |> element("#schedule-nav") |> render_click()
    view
  end

  defp row_ids(view) do
    view
    |> render()
    |> then(fn html ->
      Regex.scan(~r/id="schedule-([0-9a-f\-]{36})"/, html)
      |> Enum.map(fn [_, id] -> id end)
    end)
  end

  describe "task center list" do
    test "orders tasks that need attention first, then by the next run time", %{conn: conn} do
      {:ok, paused} = Store.pause(create_weekly("已暂停任务"))

      failing = create_weekly("失败任务")
      {:ok, _} = run_and_finish(failing, "failed")

      finished = create_once("一次性任务")
      {:ok, _} = run_and_finish(finished, "completed")

      active = create_weekly("运行中任务")
      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      ids = row_ids(view)

      assert Enum.find_index(ids, &(&1 == failing.id)) <
               Enum.find_index(ids, &(&1 == active.id))

      assert Enum.find_index(ids, &(&1 == active.id)) <
               Enum.find_index(ids, &(&1 == paused.id))

      assert Enum.find_index(ids, &(&1 == paused.id)) <
               Enum.find_index(ids, &(&1 == finished.id))
    end

    test "an attention count is visible before any filter is applied", %{conn: conn} do
      failing = create_weekly("失败任务")
      {:ok, _} = run_and_finish(failing, "failed")
      create_weekly("正常运行")

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      assert has_element?(view, "#schedule-center button[phx-value-filter='attention']", "1")
    end

    test "a slot that came and went without a run shows as overdue, not healthy", %{conn: conn} do
      delayed = create_weekly("逾期任务")

      past = DateTime.add(Handbean.Schedule.now(), -3600, :second)

      Handbean.Repo.update_all(
        from(s in Handbean.Schedule.Entry, where: s.id == ^delayed.id),
        set: [next_run_at: past]
      )

      healthy = create_weekly("正常运行")
      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      assert has_element?(view, "##{"schedule-#{delayed.id}"}", "逾期未运行")
      refute has_element?(view, "##{"schedule-#{healthy.id}"}", "逾期未运行")

      view |> element("button[phx-value-filter='attention']") |> render_click()

      assert has_element?(view, "#schedule-#{delayed.id}")
      refute has_element?(view, "#schedule-#{healthy.id}")

      ids = row_ids(view)
      assert ids == [delayed.id]
    end

    test "filtering to attention hides healthy tasks", %{conn: conn} do
      failing = create_weekly("失败任务")
      {:ok, _} = run_and_finish(failing, "failed")
      healthy = create_weekly("正常运行")

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      view |> element("button[phx-value-filter='attention']") |> render_click()

      assert has_element?(view, "#schedule-#{failing.id}")
      refute has_element?(view, "#schedule-#{healthy.id}")

      view |> element("button[phx-value-filter='all']") |> render_click()
      assert has_element?(view, "#schedule-#{healthy.id}")
    end

    test "every filter keeps the center open and returns a coherent count", %{conn: conn} do
      failing = create_weekly("失败任务")
      {:ok, _} = run_and_finish(failing, "failed")
      active = create_weekly("运行中任务")
      {:ok, paused} = Store.pause(create_weekly("已暂停任务"))
      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      for filter <- ["all", "active", "paused", "ended", "attention"] do
        view |> element("button[phx-value-filter='#{filter}']") |> render_click()
        assert has_element?(view, "#schedule-center")
      end

      view |> element("button[phx-value-filter='active']") |> render_click()
      assert has_element?(view, "#schedule-#{active.id}")
      refute has_element?(view, "#schedule-#{paused.id}")

      view |> element("button[phx-value-filter='paused']") |> render_click()
      assert has_element?(view, "#schedule-#{paused.id}")
      refute has_element?(view, "#schedule-#{active.id}")

      view |> element("button[phx-value-filter='ended']") |> render_click()
      assert has_element?(view, "#schedule-empty", "没有匹配的任务")
      assert has_element?(view, "#schedule-center")
    end

    test "searching matches the instruction text, not only the name", %{conn: conn} do
      matching = create_weekly("任务甲", instruction: "只检查 issue 列表")
      other = create_weekly("任务乙", instruction: "汇总版本号")

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      view |> element("#schedule-search-form") |> render_change(%{"query" => "issue"})

      assert has_element?(view, "#schedule-#{matching.id}")
      refute has_element?(view, "#schedule-#{other.id}")
      refute has_element?(view, "#schedule-empty")
    end

    test "empty states distinguish no tasks from no matches", %{conn: conn} do
      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      assert has_element?(view, "#schedule-empty", "还没有定时任务")

      create_weekly("唯一任务")
      view = open_center(conn, host["id"])
      view |> element("#schedule-search-form") |> render_change(%{"query" => "无匹配关键词"})

      assert has_element?(view, "#schedule-empty", "没有匹配的任务")
    end
  end

  describe "workspace scope" do
    test "the center follows the workspace you entered and can switch", %{conn: conn} do
      default_task = create_weekly("默认区任务")

      project_dir =
        Path.join(System.tmp_dir!(), "sigil_schedule_ws_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      try do
        {:ok, project} = Handbean.WorkspaceStore.add(project_dir, name: "Schedule Scope")
        {:ok, conversation} = Handbean.ConversationStore.create(project["id"], title: "项目对话")

        {:ok, project_task} =
          Store.create(%{
            workspace_id: project["id"],
            conversation_id: conversation["id"],
            name: "项目任务",
            instruction: "只属于这个工作区",
            time_zone: @zone,
            model: "fake/model",
            rule: %{"kind" => "weekly", "weekdays" => [1], "times" => ["09:00"]}
          })

        {:ok, view, _html} = live(conn, "/w/#{project["id"]}/c/#{conversation["id"]}")
        view |> element("#schedule-nav") |> render_click()

        assert has_element?(view, "#schedule-center")
        assert has_element?(view, "#schedule-workspace")
        assert has_element?(view, "#schedule-#{project_task.id}")
        refute has_element?(view, "#schedule-#{default_task.id}")
        assert render(view) =~ "任务会在「Schedule Scope」的新对话中运行并返回结果"

        view
        |> form("#schedule-workspace-form", %{"workspace_id" => "default"})
        |> render_change()

        assert has_element?(view, "#schedule-center")
        assert has_element?(view, "#schedule-#{default_task.id}")
        refute has_element?(view, "#schedule-#{project_task.id}")
        {:ok, default} = Handbean.WorkspaceStore.get("default")
        assert render(view) =~ "任务会在「#{default["name"]}」的新对话中运行并返回结果"
      after
        File.rm_rf!(project_dir)
      end
    end
  end

  describe "task center detail" do
    test "selecting a task shows its instruction and run history", %{conn: conn} do
      schedule = create_weekly("检查编译", instruction: "读取 workflow 状态并汇报")
      {:ok, _} = run_and_finish(schedule, "completed")

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      view |> element("#schedule-#{schedule.id}") |> render_click()

      html = render(view)
      assert html =~ "读取 workflow 状态并汇报"
      assert has_element?(view, "#schedule-detail", "运行历史")
      assert has_element?(view, "#schedule-detail", "成功")
    end

    test "a long instruction starts folded and can be unfolded", %{conn: conn} do
      long = String.duplicate("逐步检查项目状态。", 40)
      schedule = create_weekly("长指令任务", instruction: long)

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      view |> element("#schedule-#{schedule.id}") |> render_click()

      assert has_element?(
               view,
               "#schedule-detail button[phx-click='schedule_instruction_toggle']",
               "展开"
             )

      view
      |> element("#schedule-detail button[phx-click='schedule_instruction_toggle']")
      |> render_click()

      assert has_element?(
               view,
               "#schedule-detail button[phx-click='schedule_instruction_toggle']",
               "收起"
             )
    end

    test "a short instruction never offers the fold control", %{conn: conn} do
      schedule = create_weekly("短指令任务", instruction: "报告今天天气")

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      view |> element("#schedule-#{schedule.id}") |> render_click()

      refute has_element?(view, "button[phx-click='schedule_instruction_toggle']")
    end

    test "the detail pane opens on demand for a narrow layout", %{conn: conn} do
      schedule = create_weekly("窄屏任务")
      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      refute has_element?(view, "#schedule-detail[data-open='true']")

      view |> element("#schedule-#{schedule.id}") |> render_click()
      assert has_element?(view, "#schedule-detail[data-open='true']")

      view |> element("button[phx-click='schedule_close_detail']") |> render_click()
      refute has_element?(view, "#schedule-detail[data-open='true']")
      assert has_element?(view, "#schedule-#{schedule.id}")
    end

    test "closing the pane keeps the list and reopens on the next selection", %{conn: conn} do
      first = create_weekly("第一个任务")
      second = create_weekly("第二个任务")

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      view |> element("button[phx-click='schedule_close_detail']") |> render_click()

      assert has_element?(view, "#schedule-detail", "从左侧选择一个任务")
      assert has_element?(view, "#schedule-#{first.id}")
      assert has_element?(view, "#schedule-#{second.id}")

      view |> element("#schedule-#{second.id}") |> render_click()

      assert has_element?(view, "#schedule-detail", "第二个任务")
      refute has_element?(view, "#schedule-detail", "从左侧选择一个任务")
    end

    test "the detail pane follows the effective selection after a delete", %{conn: conn} do
      keep = create_weekly("保留任务")
      drop = create_weekly("删除任务")

      host = create_conversation("宿主对话")
      view = open_center(conn, host["id"])

      view |> element("#schedule-#{drop.id}") |> render_click()
      assert has_element?(view, "#schedule-detail", "删除任务")

      view
      |> element("#schedule-#{drop.id} button[phx-click='schedule_delete']")
      |> render_click()

      refute has_element?(view, "#schedule-#{drop.id}")
      assert has_element?(view, "#schedule-detail", "保留任务")
      assert has_element?(view, "#schedule-#{keep.id}")
    end
  end

  describe "closed task center" do
    test "the sidebar count does not require the list payload", %{conn: conn} do
      create_weekly("任务一")
      create_weekly("任务二")
      host = create_conversation("宿主对话")

      {:ok, view, _html} = live(conn, "/w/default/c/#{host["id"]}")

      refute has_element?(view, "#schedule-center")
      assert has_element?(view, "#schedule-nav", "2")
    end

    test "a closed center reads a constant number of queries as tasks accumulate", %{conn: conn} do
      host = create_conversation("宿主对话")
      {:ok, view, _html} = live(conn, "/w/default/c/#{host["id"]}")

      one_task =
        count_queries(fn -> send(view.pid, {:schedule_changed, host["id"]}) && settle(view) end)

      for i <- 1..6, do: create_weekly("任务#{i}")

      many_tasks =
        count_queries(fn ->
          send(view.pid, {:schedule_changed, host["id"]})
          settle(view)
        end)

      assert many_tasks <= one_task + 1
      refute has_element?(view, "#schedule-center")
    end
  end

  defp settle(view), do: render(view)

  defp count_queries(fun) do
    test_pid = self()
    ref = make_ref()
    counter = :counters.new(1, [])

    handler = fn _event, _measurements, _metadata, _config ->
      :counters.add(counter, 1, 1)
      send(test_pid, ref)
    end

    :telemetry.attach({__MODULE__, ref}, [:handbean, :repo, :query], handler, nil)

    try do
      fun.()
    after
      :telemetry.detach({__MODULE__, ref})
    end

    :counters.get(counter, 1)
  end
end
