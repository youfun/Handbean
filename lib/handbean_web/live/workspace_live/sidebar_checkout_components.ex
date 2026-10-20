defmodule HandbeanWeb.WorkspaceLive.SidebarCheckoutComponents do
  @moduledoc false

  use HandbeanWeb, :html

  alias HandbeanWeb.WorkspaceLive.ConversationSwitching

  attr :workspace_id, :string, required: true
  attr :picker, :any, default: nil
  attr :source, :atom, default: :sidebar

  def checkout_picker(assigns) do
    open? =
      ConversationSwitching.checkout_picker_open?(
        assigns.picker,
        assigns.workspace_id,
        assigns.source
      )

    click =
      if assigns.source == :mobile,
        do: "mobile_new_conversation_in_workspace",
        else: "new_conversation_in_workspace"

    assigns =
      assigns
      |> assign(:open?, open?)
      |> assign(:click, click)

    ~H"""
    <div class="workspace-checkout-picker">
      <button
        type="button"
        phx-click={@click}
        phx-value-ws_id={@workspace_id}
        class={[
          @source != :mobile &&
            "workspace-add-btn flex-shrink-0 w-5 h-5 flex items-center justify-center rounded text-tertiary hover:text-primary hover:bg-surface-hover transition-colors",
          @source == :mobile && "sheet-new-conv-btn",
          @open? && "is-open"
        ]}
        title={gettext("在此工作区新建对话")}
        aria-label={gettext("在此工作区新建对话")}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open?)}
      >
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
          <path
            d="M6 1v10M1 6h10"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
          />
        </svg>
      </button>
    </div>
    """
  end

  attr :picker, :any, default: nil

  def checkout_picker_dialog(assigns) do
    picker = assigns.picker

    assigns =
      assigns
      |> assign(:header?, match?(%{source: :header}, picker))
      |> assign(:dialog_id, picker_dialog_id(picker))
      |> assign(:title, picker_dialog_title(picker))
      |> assign(:projects, picker_projects(picker))
      |> assign(:checkouts, picker_checkouts(picker))
      |> assign(:workspace_id, picker_workspace_id(picker))

    ~H"""
    <div
      :if={@picker}
      id="checkout-picker-overlay"
      class="checkout-picker-overlay"
      phx-window-keydown="close_checkout_picker"
      phx-key="Escape"
    >
      <button
        type="button"
        class="checkout-picker-backdrop"
        phx-click="close_checkout_picker"
        aria-label={gettext("Close")}
      ></button>
      <div
        id={@dialog_id}
        role="dialog"
        aria-modal="true"
        aria-labelledby="checkout-picker-title"
        class="checkout-picker-dialog"
      >
        <div class="checkout-picker-header">
          <h3 id="checkout-picker-title" class="checkout-picker-title">{@title}</h3>
          <button
            type="button"
            class="checkout-picker-close"
            phx-click="close_checkout_picker"
            aria-label={gettext("Close")}
          >
            <span aria-hidden="true">×</span>
          </button>
        </div>
        <div class="checkout-picker-list">
          <%= if @header? do %>
            <%= for project <- @projects do %>
              <%= if length(project.checkouts) > 1 do %>
                <div class="workspace-checkout-heading workspace-checkout-project">
                  {project.name}
                </div>
                <.checkout_choice
                  :for={checkout <- project.checkouts}
                  checkout={checkout}
                  workspace_id={project.id}
                />
              <% else %>
                <button
                  id={"new-conversation-project-#{project.id}"}
                  type="button"
                  phx-click="new_conversation_in_workspace"
                  phx-value-ws_id={project.id}
                  phx-value-source="header"
                  class="workspace-checkout-item"
                  title={project.path}
                >
                  <span class="workspace-checkout-ref">{project.name}</span>
                  <span :if={project.path} class="workspace-checkout-path">{project.path}</span>
                </button>
              <% end %>
            <% end %>
          <% else %>
            <.checkout_choice
              :for={checkout <- @checkouts}
              checkout={checkout}
              workspace_id={@workspace_id}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :checkout, :map, required: true
  attr :workspace_id, :string, required: true

  defp checkout_choice(assigns) do
    ref = checkout_ref(assigns.checkout)
    name = Path.basename(assigns.checkout.path)

    assigns =
      assigns
      |> assign(:ref, ref)
      |> assign(:name, name)

    ~H"""
    <button
      type="button"
      phx-click="new_conversation_on_checkout"
      phx-value-ws_id={@workspace_id}
      phx-value-path={@checkout.path}
      class="workspace-checkout-item is-checkout"
      title={@checkout.path}
    >
      <span class="workspace-checkout-ref">{@ref || @name}</span>
      <span :if={@ref && @ref != @name} class="workspace-checkout-name">{@name}</span>
      <span class="workspace-checkout-path">{@checkout.path}</span>
    </button>
    """
  end

  defp picker_dialog_id(%{source: :header}), do: "new-conversation-picker"

  defp picker_dialog_id(%{source: source, workspace_id: workspace_id})
       when is_atom(source) and is_binary(workspace_id) do
    "checkout-picker-#{source}-#{workspace_id}"
  end

  defp picker_dialog_id(_picker), do: "checkout-picker"

  defp picker_dialog_title(%{source: :header}), do: gettext("新建对话")
  defp picker_dialog_title(_picker), do: gettext("Choose a checkout")

  defp picker_projects(%{source: :header, projects: projects}) when is_list(projects),
    do: projects

  defp picker_projects(_picker), do: []

  defp picker_checkouts(%{source: :header}), do: []
  defp picker_checkouts(%{checkouts: checkouts}) when is_list(checkouts), do: checkouts
  defp picker_checkouts(_picker), do: []

  defp picker_workspace_id(%{workspace_id: workspace_id}) when is_binary(workspace_id),
    do: workspace_id

  defp picker_workspace_id(_picker), do: ""

  defp checkout_ref(%{branch: branch}) when is_binary(branch) and branch != "", do: branch
  defp checkout_ref(%{detached?: true}), do: "detached"
  defp checkout_ref(_checkout), do: nil
end
