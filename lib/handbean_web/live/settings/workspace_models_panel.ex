defmodule HandbeanWeb.Live.Settings.WorkspaceModelsPanel do
  @moduledoc "Workspace model policy settings panel and event owner."

  use HandbeanWeb, :html

  alias Handbean.Agent.ModelConfig
  alias HandbeanWeb.Components.ModelPicker

  attr(:workspace, :map, required: true)
  attr(:workspace_root, :string, required: true)
  attr(:workspaces, :list, required: true)
  attr(:conversation_id, :string, default: nil)
  attr(:all_models, :list, required: true)
  attr(:policy, :map, required: true)
  attr(:query, :string, required: true)
  attr(:saving, :boolean, required: true)

  def render(assigns) do
    ~H"""
    <div class="settings-content-wrap">
      <div class="settings-content-card">
        <div class="settings-form-section">
          <div class="settings-workspace-heading">
            <div class="settings-section-heading">
              <div class="settings-section-title">{gettext("当前工作区模型")}</div>
              <div class="settings-help-text">
                <div>{@workspace["name"]}</div>
                <div class="settings-path">{@workspace_root}</div>
              </div>
            </div>

            <form
              id="workspace-models-workspace-form"
              phx-change="select_workspace_models"
              class="settings-workspace-select"
            >
              <label class="sr-only" for="workspace-models-workspace">
                {gettext("选择工作区")}
              </label>
              <select
                id="workspace-models-workspace"
                name="workspace[id]"
                class="settings-input"
              >
                <option
                  :for={workspace <- @workspaces}
                  value={workspace["id"]}
                  selected={@workspace["id"] == workspace["id"]}
                >
                  {workspace["name"]}
                </option>
              </select>
            </form>
          </div>

          <div class="settings-card">
            <div class="settings-field-row">
              <div class="settings-field-copy">
                <div class="settings-field-title">{gettext("访问模式")}</div>
                <div class="settings-field-desc">
                  {gettext("Limit which models this workspace can use.")}
                </div>
              </div>
              <div class="settings-field-control">
                <div class="flex gap-2">
                  <button
                    type="button"
                    phx-click="set_workspace_model_mode"
                    phx-value-mode="unrestricted"
                    class={[
                      "settings-chip",
                      if(@policy.mode == :unrestricted, do: "active")
                    ]}
                  >
                    {gettext("不限制")}
                  </button>
                  <button
                    type="button"
                    phx-click="set_workspace_model_mode"
                    phx-value-mode="restricted"
                    class={[
                      "settings-chip",
                      if(@policy.mode == :restricted, do: "active")
                    ]}
                  >
                    {gettext("仅允许勾选模型")}
                  </button>
                </div>
              </div>
            </div>

            <form
              id="workspace-default-model-form"
              phx-change="set_workspace_default_model"
              class="settings-field-row"
            >
              <div class="settings-field-copy">
                <label class="settings-field-title" for="workspace-default-model">
                  {gettext("工作区默认模型")}
                </label>
                <div class="settings-field-desc">
                  {gettext("Used when starting a new conversation in this workspace.")}
                </div>
              </div>
              <div class="settings-field-control">
                <ModelPicker.render
                  id="workspace-default-model"
                  name="default_model"
                  value={@policy.default_model}
                  options={workspace_default_picker_options(@policy, @all_models)}
                  label={gettext("工作区默认模型")}
                  change="set_workspace_default_model"
                />
              </div>
            </form>
          </div>

          <div :if={@policy.mode == :restricted} class="settings-model-picker-list">
            <form
              id="workspace-model-filter-form"
              phx-change="filter_workspace_models"
              class="settings-model-filter"
            >
              <label class="sr-only" for="workspace-model-filter">{gettext("搜索模型")}</label>
              <input
                id="workspace-model-filter"
                type="search"
                name="query"
                value={@query}
                placeholder={gettext("搜索模型或供应商")}
                phx-debounce="200"
                class="settings-input"
              />
            </form>

            <div class="settings-model-list">
              <div
                :for={{provider_id, models} <- filtered_models(@all_models, @query)}
                class="settings-model-provider"
              >
                <div class="settings-model-provider-header">
                  <div>
                    <div class="settings-model-provider-title">{provider_id}</div>
                    <div class="settings-model-provider-count">
                      {gettext("已选 %{selected} / %{total}",
                        selected: provider_selected_count(@policy, provider_id),
                        total: provider_model_count(@all_models, provider_id)
                      )}
                    </div>
                  </div>
                  <div class="settings-model-provider-actions">
                    <button
                      type="button"
                      phx-click="set_workspace_provider_models"
                      phx-value-provider={provider_id}
                      phx-value-action="all"
                      class="settings-btn"
                    >
                      {gettext("全选")}
                    </button>
                    <button
                      type="button"
                      phx-click="set_workspace_provider_models"
                      phx-value-provider={provider_id}
                      phx-value-action="none"
                      class="settings-btn"
                    >
                      {gettext("清空")}
                    </button>
                  </div>
                </div>
                <label :for={model <- models} class="settings-model-row">
                  <input
                    type="checkbox"
                    checked={model_checked?(@policy, provider_id, model.model_id)}
                    phx-click="toggle_workspace_model"
                    phx-value-provider={provider_id}
                    phx-value-model={model.model_id}
                  />
                  <span>{model.name || model.model_id}</span>
                </label>
              </div>
            </div>

            <div
              :if={filtered_models(@all_models, @query) == []}
              class="settings-model-empty"
            >
              {gettext("没有匹配的模型")}
            </div>
          </div>
        </div>

        <div class="settings-page-actions">
          <button
            phx-click="save_workspace_models"
            disabled={@saving}
            class="settings-save-btn"
          >
            {if @saving, do: gettext("Saving..."), else: gettext("Save")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  def init(socket, workspace_root) do
    socket
    |> assign(:all_models, ModelConfig.all_global_models())
    |> assign(:workspace_model_policy, load_policy(workspace_root))
    |> assign(:workspace_model_query, "")
    |> assign(:workspace_models_saving, false)
  end

  def assign_context(socket, workspace) do
    if socket.assigns.workspace["id"] == workspace["id"] do
      socket
    else
      workspace_root = workspace["path"] || Path.expand(".")

      socket
      |> assign(:workspace, workspace)
      |> assign(:workspace_root, workspace_root)
      |> assign(:workspace_model_policy, load_policy(workspace_root))
      |> assign(:workspace_model_query, "")
      |> assign(:workspace_models_saving, false)
      |> update(:errors, &Map.delete(&1, :general))
    end
  end

  def handle_event("set_workspace_model_mode", %{"mode" => mode}, socket) do
    policy =
      Map.put(
        socket.assigns.workspace_model_policy,
        :mode,
        if(mode == "restricted", do: :restricted, else: :unrestricted)
      )

    {:noreply, assign(socket, :workspace_model_policy, policy)}
  end

  def handle_event(
        "select_workspace_models",
        %{"workspace" => %{"id" => workspace_id}},
        socket
      ) do
    case Enum.find(socket.assigns.workspaces, &(&1["id"] == workspace_id)) do
      nil ->
        {:noreply, socket}

      workspace ->
        query =
          %{
            "tab" => "workspace_models",
            "workspace_id" => workspace["id"],
            "conversation_id" => socket.assigns.conversation_id
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        {:noreply, Phoenix.LiveView.push_patch(socket, to: ~p"/settings?#{query}")}
    end
  end

  def handle_event("filter_workspace_models", %{"query" => query}, socket) do
    {:noreply, assign(socket, :workspace_model_query, String.trim(query))}
  end

  def handle_event(
        "set_workspace_provider_models",
        %{"provider" => provider, "action" => action},
        socket
      ) do
    policy = socket.assigns.workspace_model_policy
    allowed = Map.get(policy, :allowed, %{})

    allowed =
      if action == "all" do
        model_ids =
          socket.assigns.all_models
          |> Enum.filter(&(&1.provider_id == provider))
          |> Enum.map(& &1.model_id)
          |> MapSet.new()

        if MapSet.size(model_ids) == 0,
          do: Map.delete(allowed, provider),
          else: Map.put(allowed, provider, model_ids)
      else
        Map.delete(allowed, provider)
      end

    policy =
      policy
      |> Map.put(:mode, :restricted)
      |> Map.put(:allowed, allowed)
      |> clear_invalid_default()

    {:noreply, assign(socket, :workspace_model_policy, policy)}
  end

  def handle_event("toggle_workspace_model", %{"provider" => provider, "model" => model}, socket) do
    policy = socket.assigns.workspace_model_policy
    allowed = Map.get(policy, :allowed, %{})
    models = Map.get(allowed, provider, MapSet.new())

    models =
      if MapSet.member?(models, model),
        do: MapSet.delete(models, model),
        else: MapSet.put(models, model)

    allowed =
      if MapSet.size(models) == 0,
        do: Map.delete(allowed, provider),
        else: Map.put(allowed, provider, models)

    policy =
      policy
      |> Map.put(:mode, :restricted)
      |> Map.put(:allowed, allowed)
      |> clear_invalid_default()

    {:noreply, assign(socket, :workspace_model_policy, policy)}
  end

  def handle_event("set_workspace_default_model", %{"default_model" => default_model}, socket) do
    policy =
      Map.put(socket.assigns.workspace_model_policy, :default_model, blank_to_nil(default_model))

    {:noreply, assign(socket, :workspace_model_policy, policy)}
  end

  def handle_event("save_workspace_models", _params, socket) do
    socket = assign(socket, :workspace_models_saving, true)

    case save_policy(socket.assigns.workspace_root, socket.assigns.workspace_model_policy) do
      :ok ->
        toast = %{
          type: :success,
          message: gettext("工作区模型保存成功"),
          id: System.unique_integer([:positive])
        }

        Process.send_after(self(), :clear_toast, 3000)

        {:noreply,
         socket
         |> assign(:workspace_models_saving, false)
         |> assign(:available_models, ModelConfig.all_global_models())
         |> assign(:workspace_model_policy, load_policy(socket.assigns.workspace_root))
         |> assign(:toast, toast)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:workspace_models_saving, false)
         |> assign(:errors, %{general: format_error(reason)})}
    end
  end

  defp load_policy(workspace_root) do
    case ModelConfig.load_workspace_policy(workspace_root) do
      :unrestricted ->
        %{mode: :unrestricted, allowed: %{}, default_model: nil}

      {:ok, policy} ->
        providers = policy |> Map.get("allow", %{}) |> allowed_providers()

        %{
          mode: if(providers == %{}, do: :unrestricted, else: :restricted),
          allowed: allowed_model_sets(providers),
          default_model: default_model_from_policy(policy)
        }

      {:error, _reason} ->
        %{mode: :unrestricted, allowed: %{}, default_model: nil}
    end
  end

  defp allowed_providers(%{"providers" => providers}) when is_map(providers), do: providers
  defp allowed_providers(allow) when is_map(allow), do: allow
  defp allowed_providers(_allow), do: %{}

  defp allowed_model_sets(providers) do
    Map.new(providers, fn {provider, config} ->
      models = config |> Map.get("models", []) |> Enum.filter(&is_binary/1) |> MapSet.new()
      {provider, models}
    end)
  end

  defp default_model_from_policy(policy) do
    default = Map.get(policy, "default", %{})
    provider = Map.get(default, "provider")
    model = Map.get(default, "model")

    if is_binary(provider) and is_binary(model), do: "#{provider}/#{model}"
  end

  defp clear_invalid_default(%{default_model: nil} = policy), do: policy

  defp clear_invalid_default(%{default_model: default_model} = policy) do
    if model_allowed?(policy, default_model),
      do: policy,
      else: Map.put(policy, :default_model, nil)
  end

  defp model_allowed?(%{mode: :unrestricted}, model_id) when is_binary(model_id), do: true

  defp model_allowed?(%{allowed: allowed}, model_id) when is_binary(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [provider, model] -> allowed |> Map.get(provider, MapSet.new()) |> MapSet.member?(model)
      _ -> false
    end
  end

  defp model_allowed?(_policy, _model_id), do: false

  defp model_checked?(policy, provider, model) do
    policy.mode == :unrestricted or
      policy.allowed
      |> Map.get(provider, MapSet.new())
      |> MapSet.member?(model)
  end

  defp workspace_default_picker_options(policy, all_models) do
    options = Enum.filter(all_models, &model_allowed?(policy, &1.id))

    [ModelPicker.option("", gettext("使用供应商默认"))] ++
      Enum.map(options, fn model ->
        ModelPicker.option(model.id, model.name || model.model_id, model.provider_id)
      end)
  end

  defp filtered_models(models, query) do
    normalized_query = query |> to_string() |> String.downcase()

    models
    |> Enum.filter(fn model ->
      normalized_query == "" or
        Enum.any?([model.provider_id, model.model_id, model.name], fn value ->
          is_binary(value) and String.contains?(String.downcase(value), normalized_query)
        end)
    end)
    |> Enum.group_by(& &1.provider_id)
    |> Enum.sort_by(fn {provider_id, _models} -> provider_id end)
  end

  defp provider_selected_count(policy, provider_id) do
    policy.allowed |> Map.get(provider_id, MapSet.new()) |> MapSet.size()
  end

  defp provider_model_count(models, provider_id) do
    Enum.count(models, &(&1.provider_id == provider_id))
  end

  defp save_policy(workspace_root, policy) do
    with {:ok, settings} <- Handbean.WorkspaceSettings.load(workspace_root),
         :ok <- File.mkdir_p(Path.dirname(Handbean.WorkspaceSettings.path(workspace_root))) do
      settings
      |> Map.put("models", policy_to_json(policy))
      |> then(
        &File.write(
          Handbean.WorkspaceSettings.path(workspace_root),
          Handbean.JSON.encode!(&1, pretty: true)
        )
      )
      |> case do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write workspace settings: #{inspect(reason)}"}
      end
    end
  end

  defp policy_to_json(%{mode: :unrestricted}), do: %{"allow" => %{"providers" => %{}}}

  defp policy_to_json(policy) do
    providers =
      policy.allowed
      |> Enum.reject(fn {_provider, models} -> MapSet.size(models) == 0 end)
      |> Map.new(fn {provider, models} ->
        {provider, %{"models" => models |> MapSet.to_list() |> Enum.sort()}}
      end)

    %{"allow" => %{"providers" => providers}}
    |> maybe_put_default(policy.default_model)
  end

  defp maybe_put_default(json, nil), do: json

  defp maybe_put_default(json, default_model) do
    case String.split(default_model, "/", parts: 2) do
      [provider, model] -> Map.put(json, "default", %{"provider" => provider, "model" => model})
      _ -> json
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
