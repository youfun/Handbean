defmodule HandbeanWeb.FileMovePlanComponent do
  @moduledoc false

  use HandbeanWeb, :live_component

  alias Handbean.FileMovePlans

  @impl true
  def mount(socket) do
    {:ok, assign(socket, plan: nil, phase: :select, selected_ids: [], error: nil)}
  end

  @impl true
  def update(assigns, socket) do
    binding_changed? =
      socket.assigns[:context] != assigns.context or
        socket.assigns[:plan_id] != assigns.plan_id

    socket =
      if binding_changed? do
        assign(socket, plan: nil, phase: :select, selected_ids: [], error: nil)
      else
        socket
      end

    {:ok, socket |> assign(assigns) |> load_plan()}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :preview_entries, selected_entries(assigns.plan, assigns.selected_ids))

    ~H"""
    <section id={@id} class="mt-2 rounded border border-edge p-3 text-xs text-primary">
      <p :if={@error} role="alert" class="text-error">{@error}</p>
      <div :if={@plan}>
        <h3 class="font-semibold">{@plan.title}</h3>
        <p class="mt-1 text-secondary">{status_label(@plan.status)}</p>
        <p class="mt-1 break-all text-tertiary">
          {gettext("工作目录：")}<code>{@plan.checkout_path}</code>
        </p>
        <p
          :if={
            to_string(@plan.status) == "needs_review" or
              Enum.any?(@plan.entries, &(&1["status"] == "moving"))
          }
          role="alert"
          class="mt-2 text-error"
        >
          {gettext("存在移动中断或结果尚未确认的文件，请人工核对源路径和目标路径后再操作。")}
        </p>

        <form
          :if={to_string(@plan.status) == "draft" && @phase == :select && is_nil(@error)}
          id={"#{@id}-selection"}
          phx-change="select"
          phx-submit="preview"
          phx-target={@myself}
          class="mt-2 space-y-2"
        >
          <input type="hidden" name="selected_ids[]" value="" />
          <label :for={entry <- @plan.entries} class="flex min-h-11 items-start gap-2 py-2">
            <input
              type="checkbox"
              name="selected_ids[]"
              value={entry["id"]}
              checked={entry["id"] in @selected_ids}
              class="mt-1"
            />
            <span class="min-w-0 flex-1">
              <span class="block break-all"><code>{entry["source"]}</code></span>
              <span class="block break-all">{gettext("目标：")}<code>{entry["target"]}</code></span>
              <span :if={entry["reason"]} class="mt-1 block text-secondary">{entry["reason"]}</span>
            </span>
          </label>
          <button type="submit" disabled={@selected_ids == []} class="min-h-11 rounded border px-3">
            {gettext("预览所选移动")}
          </button>
        </form>

        <div
          :if={to_string(@plan.status) == "draft" && @phase == :preview && is_nil(@error)}
          class="mt-2"
        >
          <p>{gettext("请核对以下精确路径。确认后将请求 Agent 执行这些选项。")}</p>
          <dl :for={entry <- @preview_entries} class="mt-2 rounded border border-edge p-2">
            <dt class="text-secondary">{gettext("源路径")}</dt>
            <dd class="break-all whitespace-pre-wrap"><code>{entry["source"]}</code></dd>
            <dt class="mt-1 text-secondary">{gettext("目标路径")}</dt>
            <dd class="break-all whitespace-pre-wrap"><code>{entry["target"]}</code></dd>
            <dd :if={entry["reason"]} class="mt-1 text-secondary">{entry["reason"]}</dd>
          </dl>
          <div class="mt-2 flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="cancel"
              phx-target={@myself}
              class="min-h-11 rounded border px-3"
            >
              {gettext("取消")}
            </button>
            <button
              type="button"
              phx-click="confirm"
              phx-target={@myself}
              class="min-h-11 rounded border px-3"
            >
              {gettext("确认并请求执行")}
            </button>
          </div>
        </div>

        <div :if={to_string(@plan.status) != "draft"} class="mt-2 space-y-2">
          <div :for={entry <- @plan.entries} class="rounded border border-edge p-2">
            <p class="break-all whitespace-pre-wrap"><code>{entry["source"]}</code></p>
            <p class="break-all whitespace-pre-wrap">
              {gettext("目标：")}<code>{entry["target"]}</code>
            </p>
            <p class="mt-1 text-secondary">
              {status_label(entry["status"])}
              <span :if={entry["id"] not in @plan.selected_ids}> · {gettext("未选择")}</span>
            </p>
            <p :if={entry["error"]} class="mt-1 break-words text-error">{entry["error"]}</p>
          </div>
          <button
            :if={to_string(@plan.status) == "confirmed" && is_nil(@error)}
            type="button"
            phx-click="retry"
            phx-target={@myself}
            class="min-h-11 rounded border px-3"
          >
            {gettext("再次请求执行已确认选项")}
          </button>
        </div>
      </div>
      <button
        :if={@error}
        type="button"
        phx-click="refresh"
        phx-target={@myself}
        class="mt-2 min-h-11 rounded border px-3"
      >
        {gettext("刷新计划")}
      </button>
    </section>
    """
  end

  @impl true
  def handle_event("select", params, socket) do
    {:noreply, select_entries(socket, params)}
  end

  def handle_event("preview", params, socket) do
    socket = select_entries(socket, params)

    socket =
      if socket.assigns.selected_ids != [] && draft?(socket) do
        assign(socket, :phase, :preview)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:phase, :select) |> load_plan()}
  end

  def handle_event("confirm", _params, socket) do
    if socket.assigns.phase == :preview && draft?(socket) && socket.assigns.selected_ids != [] do
      case FileMovePlans.confirm(
             socket.assigns.context,
             socket.assigns.plan_id,
             socket.assigns.plan.version,
             socket.assigns.selected_ids
           ) do
        {:ok, plan} ->
          send(self(), {:file_move_plan_confirmed, plan.id})
          {:noreply, socket |> assign(:phase, :select) |> load_plan()}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:phase, :select)
           |> load_plan()
           |> assign(:error, error_message(reason))}
      end
    else
      {:noreply, load_plan(socket)}
    end
  end

  def handle_event("retry", _params, socket) do
    socket = load_plan(socket)

    if socket.assigns.plan && is_nil(socket.assigns.error) &&
         to_string(socket.assigns.plan.status) == "confirmed" do
      send(self(), {:file_move_plan_confirmed, socket.assigns.plan.id})
    end

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_plan(socket)}

  defp load_plan(socket) do
    result =
      if valid_context?(socket.assigns.context) do
        FileMovePlans.get(socket.assigns.context, socket.assigns.plan_id)
      else
        {:error, :unbound_context}
      end

    case result do
      {:ok, plan} ->
        old_plan = socket.assigns.plan
        changed? = is_nil(old_plan) or old_plan.version != plan.version

        selected_ids =
          if changed?, do: plan.selected_ids, else: socket.assigns.selected_ids

        socket
        |> assign(:plan, plan)
        |> assign(:selected_ids, selected_ids)
        |> assign(:phase, if(changed?, do: :select, else: socket.assigns.phase))
        |> assign(:error, nil)

      {:error, reason} ->
        assign(socket, :error, error_message(reason))
    end
  end

  defp select_entries(socket, params) do
    socket = load_plan(socket)

    if draft?(socket) do
      requested = params["selected_ids"] || []
      requested = if is_list(requested), do: requested, else: []

      ids =
        socket.assigns.plan.entries
        |> Enum.map(& &1["id"])
        |> Enum.filter(&(&1 in requested))

      assign(socket, selected_ids: ids, phase: :select)
    else
      socket
    end
  end

  defp draft?(socket) do
    valid_context?(socket.assigns.context) && is_nil(socket.assigns.error) &&
      not is_nil(socket.assigns.plan) && to_string(socket.assigns.plan.status) == "draft"
  end

  defp valid_context?(%{
         conversation_id: conversation_id,
         workspace_id: workspace_id,
         working_directory: path
       }) do
    Enum.all?([conversation_id, workspace_id, path], &(is_binary(&1) && &1 != ""))
  end

  defp valid_context?(_), do: false

  defp selected_entries(nil, _ids), do: []
  defp selected_entries(plan, ids), do: Enum.filter(plan.entries, &(&1["id"] in ids))

  defp error_message(:unbound_context), do: gettext("当前会话未绑定有效工作目录，无法读取文件整理计划。")
  defp error_message(:not_found), do: gettext("计划不存在，或不属于当前会话和工作目录。")
  defp error_message(:expired_plan), do: gettext("计划已过期，请重新生成文件整理计划。")
  defp error_message(:stale_plan), do: gettext("计划已更新，请刷新并重新核对选项。")
  defp error_message(:invalid_selection), do: gettext("所选项目无效，请重新勾选。")
  defp error_message(_), do: gettext("无法读取或确认计划，请刷新后重试，并重新核对选项。")

  defp status_label(status) when is_atom(status), do: status_label(Atom.to_string(status))
  defp status_label("draft"), do: gettext("待选择")
  defp status_label("confirmed"), do: gettext("已确认，等待执行")
  defp status_label("executing"), do: gettext("执行中")
  defp status_label("needs_review"), do: gettext("执行中断，请人工核对")
  defp status_label("completed"), do: gettext("已完成")
  defp status_label("failed"), do: gettext("执行失败，请核对结果")
  defp status_label("moving"), do: gettext("移动中，请核对结果")
  defp status_label("pending"), do: gettext("待执行")
  defp status_label("skipped"), do: gettext("已跳过")
  defp status_label(status), do: status
end
