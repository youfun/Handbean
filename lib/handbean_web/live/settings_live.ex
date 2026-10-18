defmodule HandbeanWeb.SettingsLive do
  @moduledoc """
  Unified full-screen Settings page.

  Provides a left menu and renders each settings section in the right panel. Uses
  `live_render` to nest independent LiveViews (e.g. AvailableModelsLive) for complex
  sections, keeping each section's state, events and PubSub subscriptions
  self-contained.

  ## Menu

    - Model / AI         → inline form (default)
    - Workspace Models   → workspace allowlist/default model
    - Workspace Memory   → nested memory browser
    - Available Models   → nested AvailableModelsLive via live_render
    - Advanced           → browser-local diagnostics
    - MCP / Git / UI     → integration and appearance settings
  """

  use HandbeanWeb, :live_view

  alias Handbean.Settings
  alias Handbean.Settings.ModelAISettings
  alias Handbean.Agent.ModelConfig
  alias HandbeanWeb.Components.ModelPicker
  alias HandbeanWeb.Live.Settings.ModelAIPanel

  @tabs [
    %{id: :model_ai, label_key: "Model / AI"},
    %{id: :workspace_models, label_key: "Workspace Models"},
    %{id: :workspace_memory, label_key: "Workspace Memory"},
    %{id: :available_models, label_key: "Available Models"},
    %{id: :local_webgpu, label_key: "Local WebGPU"},
    %{id: :mcp, label_key: "MCP"},
    %{id: :git, label_key: "Git"},
    %{id: :ui, label_key: "UI"}
  ]

  @impl true
  def mount(params, _session, socket) do
    active_tab = tab_from_params(params)

    {:ok, default_ws} = Handbean.WorkspaceStore.ensure_default!()
    workspaces = Handbean.WorkspaceStore.list()

    workspace = workspace_from_params(params, workspaces, default_ws)

    workspace_root = workspace["path"] || Path.expand(".")
    conversation_id = Map.get(params, "conversation_id")

    _ = ModelConfig.ensure_config()

    # Global Model / AI settings must show the global model catalog, not the
    # current workspace allowlist-filtered view.
    available_models = ModelConfig.all_global_models()

    # Load Model/AI settings
    {:ok, global} = Settings.load_global()
    form = ModelAISettings.new(Map.get(global, "model_ai", %{}))

    socket =
      socket
      |> assign(:page_title, gettext("Settings"))
      |> assign(:active_tab, active_tab)
      |> assign(:tabs, @tabs)
      |> assign(:workspaces, workspaces)
      |> assign(:workspace, workspace)
      |> assign(:return_workspace_id, workspace["id"])
      |> assign(:workspace_root, workspace_root)
      |> assign(:conversation_id, conversation_id)
      |> assign(:all_models, ModelConfig.all_global_models())
      |> assign(:available_models, available_models)
      |> assign(:workspace_model_policy, load_workspace_model_policy_form(workspace_root))
      |> assign(:workspace_model_query, "")
      |> assign(:form, form)
      |> assign(:errors, %{})
      |> assign(:saving, false)
      |> assign(:workspace_models_saving, false)
      |> assign(:toast, nil)
      |> assign(:runtime_banner, nil)
      |> subscribe_to_runtime_tasks()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    active_tab = tab_from_params(params)

    workspace =
      workspace_from_params(params, socket.assigns.workspaces, socket.assigns.workspace)

    {:noreply,
     socket
     |> assign(:active_tab, active_tab)
     |> assign_workspace_model_context(workspace)}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab_str}, socket) do
    tab = tab_from_params(%{"tab" => tab_str})
    ws_id = socket.assigns.workspace["id"]
    conv_id = socket.assigns.conversation_id

    query = %{"tab" => tab_str}
    query = if ws_id, do: Map.put(query, "workspace_id", ws_id), else: query
    query = if conv_id, do: Map.put(query, "conversation_id", conv_id), else: query

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> push_patch(to: ~p"/settings?#{query}")}
  end

  def handle_event("set_theme", %{"theme" => theme}, socket) do
    case Handbean.Settings.UI.save_theme(theme) do
      :ok ->
        {:noreply, socket |> assign(:theme, theme) |> push_event("set-theme", %{theme: theme})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save theme preference."))}
    end
  end

  def handle_event("set_locale", %{"locale" => locale}, socket) do
    case Handbean.Settings.UI.save_locale(locale) do
      :ok ->
        query =
          %{
            "tab" => "ui",
            "workspace_id" => socket.assigns.workspace["id"],
            "conversation_id" => socket.assigns.conversation_id
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        {:noreply, redirect(socket, to: ~p"/settings?#{query}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save language preference."))}
    end
  end

  def handle_event("update_field", params, socket) do
    {field, value} = extract_field_value(params)
    form = update_form_field(socket.assigns.form, field, value)
    errors = validate_form(form)
    {:noreply, socket |> assign(:form, form) |> assign(:errors, errors)}
  end

  def handle_event("toggle_reflector", _params, socket) do
    form = %{
      socket.assigns.form
      | om_reflector_enabled: !socket.assigns.form.om_reflector_enabled
    }

    errors = validate_form(form)
    {:noreply, socket |> assign(:form, form) |> assign(:errors, errors)}
  end

  def handle_event("save_settings", _params, socket) do
    form = socket.assigns.form
    errors = validate_form(form)

    if errors == %{} do
      {:noreply, socket |> assign(:saving, true)}

      # Save global Model/AI settings
      defaults = ModelAISettings.defaults()
      json = ModelAISettings.snapshot_model_ai(defaults, form, :global)
      {:ok, existing} = Settings.load_global()
      current = Map.get(existing, "model_ai", %{})
      current_memory = Map.get(current, "observational_memory", %{})

      if json != %{} or Map.has_key?(current, "advisor") or
           Map.has_key?(current_memory, "reflector_enabled") do
        Settings.save_global(json)
      end

      send(self(), {:settings_saved, form})

      toast = %{
        type: :success,
        message: gettext("设置保存成功"),
        id: System.unique_integer([:positive])
      }

      Process.send_after(self(), :clear_toast, 3000)

      {:noreply,
       socket
       |> assign(:saving, false)
       |> assign(:active_tab, :model_ai)
       |> assign(:toast, toast)}
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  def handle_event("set_workspace_model_mode", %{"mode" => mode}, socket) do
    policy = socket.assigns.workspace_model_policy

    policy =
      case mode do
        "restricted" -> Map.put(policy, :mode, :restricted)
        _ -> Map.put(policy, :mode, :unrestricted)
      end

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

        {:noreply, push_patch(socket, to: ~p"/settings?#{query}")}
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
      case action do
        "all" ->
          model_ids =
            socket.assigns.all_models
            |> Enum.filter(&(&1.provider_id == provider))
            |> Enum.map(& &1.model_id)
            |> MapSet.new()

          if MapSet.size(model_ids) == 0,
            do: Map.delete(allowed, provider),
            else: Map.put(allowed, provider, model_ids)

        _ ->
          Map.delete(allowed, provider)
      end

    policy =
      policy
      |> Map.put(:mode, :restricted)
      |> Map.put(:allowed, allowed)
      |> clear_invalid_workspace_default()

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
      |> clear_invalid_workspace_default()

    {:noreply, assign(socket, :workspace_model_policy, policy)}
  end

  def handle_event("set_workspace_default_model", %{"default_model" => default_model}, socket) do
    policy =
      socket.assigns.workspace_model_policy
      |> Map.put(:default_model, blank_to_nil(default_model))

    {:noreply, assign(socket, :workspace_model_policy, policy)}
  end

  def handle_event("save_workspace_models", _params, socket) do
    socket = assign(socket, :workspace_models_saving, true)

    case save_workspace_model_policy(
           socket.assigns.workspace_root,
           socket.assigns.workspace_model_policy
         ) do
      :ok ->
        workspace_root = socket.assigns.workspace_root

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
         |> assign(:workspace_model_policy, load_workspace_model_policy_form(workspace_root))
         |> assign(:toast, toast)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:workspace_models_saving, false)
         |> assign(:errors, %{general: format_error(reason)})}
    end
  end

  # ── Info ──

  @impl true
  def handle_info({:settings_saved, _form}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_toast, socket) do
    {:noreply, assign(socket, :toast, nil)}
  end

  def handle_info({:runtime_tasks, snapshot}, socket) do
    {:noreply, assign_runtime_banner(socket, snapshot)}
  end

  def handle_info({:in_app_ended, task, reason}, socket) do
    {:noreply, put_flash(socket, :info, in_app_ended_flash(task, reason))}
  end

  # ── Public helpers (used in template) ──

  defp subscribe_to_runtime_tasks(socket) do
    if connected?(socket) do
      Handbean.Runtime.TaskTracker.subscribe()
      Handbean.Runtime.TaskTracker.viewing(self(), nil)
      assign_runtime_banner(socket, Handbean.Runtime.TaskTracker.snapshot())
    else
      socket
    end
  end

  defp assign_runtime_banner(socket, snapshot) do
    assign(socket, :runtime_banner, runtime_banner_text(snapshot))
  end

  defp runtime_banner_text(%{running_count: 0, waiting_count: 0}), do: nil

  defp runtime_banner_text(%{running_count: running, waiting_count: waiting})
       when waiting > 0 and running > 0 do
    gettext("Running %{running} · waiting %{waiting}", running: running, waiting: waiting)
  end

  defp runtime_banner_text(%{waiting_count: waiting}) when waiting > 0 do
    ngettext("Needs confirmation", "Needs confirmation · %{count} tasks", waiting, count: waiting)
  end

  defp runtime_banner_text(%{running_count: running}) do
    ngettext("Running 1 task", "Running %{count} tasks", running, count: running)
  end

  defp in_app_ended_flash(task, reason) do
    %{
      body: in_app_ended_message(task, reason),
      navigate: in_app_ended_path(task),
      navigate_with: :navigate
    }
  end

  defp in_app_ended_path(%{conversation_id: conv_id, workspace_id: ws_id})
       when is_binary(conv_id) and is_binary(ws_id) and conv_id != "" and ws_id != "" do
    "/w/#{ws_id}/c/#{conv_id}"
  end

  defp in_app_ended_path(_task), do: nil

  defp in_app_ended_message(task, reason) do
    title = task[:title] || gettext("conversation")

    case reason do
      :cancelled -> gettext("Agent stopped in %{title}.", title: title)
      :failed -> gettext("This run ended in %{title}.", title: title)
      _ -> gettext("Agent replied in %{title}.", title: title)
    end
  end

  def tab_label(:model_ai), do: gettext("Model / AI")
  def tab_label(:workspace_models), do: gettext("Workspace Models")
  def tab_label(:workspace_memory), do: gettext("Workspace Memory")
  def tab_label(:available_models), do: gettext("Available Models")
  def tab_label(:local_webgpu), do: gettext("Advanced")
  def tab_label(:mcp), do: gettext("MCP")
  def tab_label(:git), do: gettext("Git")
  def tab_label(:ui), do: gettext("UI")
  def tab_label(:sns), do: gettext("SNS")
  def tab_label(:tools), do: gettext("Tools")
  def tab_label(:security), do: gettext("Security")

  def tab_icon(:model_ai), do: "🧠"
  def tab_icon(:workspace_models), do: "▦"
  def tab_icon(:workspace_memory), do: "◉"
  def tab_icon(:available_models), do: "🔧"
  def tab_icon(:ui), do: "🎨"
  def tab_icon(:sns), do: "📡"
  def tab_icon(:tools), do: "🔒"
  def tab_icon(:security), do: "🛡️"

  # ── Helpers ──

  defp theme_click(theme) do
    JS.set_attribute({"data-theme", theme}, to: "html")
    |> JS.push("set_theme", value: %{theme: theme})
  end

  defp tab_from_params(%{"tab" => tab_str}) do
    Enum.find_value(@tabs, :model_ai, fn tab ->
      if Atom.to_string(tab.id) == tab_str, do: tab.id
    end)
  end

  defp tab_from_params(_params), do: :model_ai

  defp workspace_from_params(params, workspaces, current_workspace) do
    default_workspace =
      Enum.find(workspaces, current_workspace, &(&1["default"] == true))

    case Map.get(params, "workspace_id") do
      workspace_id when is_binary(workspace_id) ->
        Enum.find(workspaces, default_workspace, &(&1["id"] == workspace_id))

      _ ->
        default_workspace
    end
  end

  defp assign_workspace_model_context(socket, workspace) do
    if socket.assigns.workspace["id"] == workspace["id"] do
      socket
    else
      workspace_root = workspace["path"] || Path.expand(".")

      socket
      |> assign(:workspace, workspace)
      |> assign(:workspace_root, workspace_root)
      |> assign(:workspace_model_policy, load_workspace_model_policy_form(workspace_root))
      |> assign(:workspace_model_query, "")
      |> assign(:workspace_models_saving, false)
      |> update(:errors, &Map.delete(&1, :general))
    end
  end

  defp extract_field_value(params) do
    field =
      params
      |> Enum.find(fn {k, _v} -> k not in ["_target", "__changed__"] end)
      |> then(fn
        nil -> ""
        {k, _} -> k
      end)

    {field, Map.get(params, field, "")}
  end

  defp update_form_field(form, "default_model", value) do
    updates = [default_model: blank_to_nil(value)]

    updates =
      if is_nil(form.om_model), do: Keyword.put(updates, :om_reasoning, nil), else: updates

    struct!(form, updates)
  end

  defp update_form_field(form, "advisor_model", value) do
    case blank_to_nil(value) do
      nil ->
        struct!(form, advisor_mode: :inherit, advisor_model: nil, advisor_reasoning: nil)

      model ->
        struct!(form, advisor_mode: :custom, advisor_model: model, advisor_reasoning: nil)
    end
  end

  defp update_form_field(form, "advisor_reasoning", value) do
    struct!(form, advisor_reasoning: blank_to_nil(value))
  end

  defp update_form_field(form, "reasoning", value) do
    struct!(form, reasoning: value)
  end

  defp update_form_field(form, "om_model", value) do
    struct!(form, om_model: blank_to_nil(value), om_reasoning: nil)
  end

  defp update_form_field(form, "om_reasoning", value) do
    struct!(form, om_reasoning: blank_to_nil(value))
  end

  defp update_form_field(form, "om_memory_scope", value) do
    struct!(form, om_memory_scope: value)
  end

  defp update_form_field(form, "om_privacy_mode", value) do
    struct!(form, om_privacy_mode: value)
  end

  defp update_form_field(form, _field, _value), do: form

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp validate_form(form) do
    map = %{
      om_privacy_mode: form.om_privacy_mode,
      om_memory_scope: form.om_memory_scope,
      om_reflector_enabled: form.om_reflector_enabled
    }

    case ModelAISettings.validate(map) do
      :ok -> %{}
      {:error, reason} -> %{general: reason}
    end
  end

  defp load_workspace_model_policy_form(workspace_root) do
    case ModelConfig.load_workspace_policy(workspace_root) do
      :unrestricted ->
        %{mode: :unrestricted, allowed: %{}, default_model: nil}

      {:ok, policy} ->
        allow = Map.get(policy, "allow", %{})
        providers = allowed_providers_from_allow(allow)

        %{
          mode: if(providers == %{}, do: :unrestricted, else: :restricted),
          allowed: allowed_model_sets(providers),
          default_model: default_model_from_policy(policy)
        }

      {:error, _reason} ->
        %{mode: :unrestricted, allowed: %{}, default_model: nil}
    end
  end

  defp allowed_providers_from_allow(%{"providers" => providers}) when is_map(providers),
    do: providers

  defp allowed_providers_from_allow(allow) when is_map(allow), do: allow
  defp allowed_providers_from_allow(_allow), do: %{}

  defp allowed_model_sets(providers) do
    Map.new(providers, fn {provider, config} ->
      models =
        config
        |> Map.get("models", [])
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      {provider, models}
    end)
  end

  defp default_model_from_policy(policy) do
    default = Map.get(policy, "default", %{})
    provider = Map.get(default, "provider")
    model = Map.get(default, "model")

    if is_binary(provider) and is_binary(model), do: "#{provider}/#{model}"
  end

  defp clear_invalid_workspace_default(%{default_model: nil} = policy), do: policy

  defp clear_invalid_workspace_default(%{default_model: default_model} = policy) do
    if workspace_model_allowed?(policy, default_model),
      do: policy,
      else: Map.put(policy, :default_model, nil)
  end

  defp workspace_model_allowed?(%{mode: :unrestricted}, model_id) when is_binary(model_id),
    do: true

  defp workspace_model_allowed?(%{allowed: allowed}, model_id) when is_binary(model_id) do
    case String.split(model_id, "/", parts: 2) do
      [provider, model] -> allowed |> Map.get(provider, MapSet.new()) |> MapSet.member?(model)
      _ -> false
    end
  end

  defp workspace_model_allowed?(_policy, _model_id), do: false

  defp workspace_model_checked?(policy, provider, model) do
    policy.mode == :unrestricted or
      policy.allowed
      |> Map.get(provider, MapSet.new())
      |> MapSet.member?(model)
  end

  defp workspace_default_options(policy, all_models) do
    all_models
    |> Enum.filter(fn model -> workspace_model_allowed?(policy, model.id) end)
  end

  defp workspace_default_picker_options(policy, all_models) do
    [ModelPicker.option("", gettext("使用供应商默认"))] ++
      Enum.map(workspace_default_options(policy, all_models), fn model ->
        ModelPicker.option(model.id, model.name || model.model_id, model.provider_id)
      end)
  end

  defp filtered_models_grouped_by_provider(models, query) do
    normalized_query = query |> to_string() |> String.downcase()

    models
    |> Enum.filter(fn model ->
      normalized_query == "" or
        Enum.any?([model.provider_id, model.model_id, model.name], fn value ->
          is_binary(value) and String.contains?(String.downcase(value), normalized_query)
        end)
    end)
    |> models_grouped_by_provider()
  end

  defp workspace_provider_selected_count(policy, provider_id) do
    policy.allowed
    |> Map.get(provider_id, MapSet.new())
    |> MapSet.size()
  end

  defp workspace_provider_model_count(models, provider_id) do
    Enum.count(models, &(&1.provider_id == provider_id))
  end

  defp models_grouped_by_provider(models) do
    models
    |> Enum.group_by(& &1.provider_id)
    |> Enum.sort_by(fn {provider_id, _models} -> provider_id end)
  end

  defp save_workspace_model_policy(workspace_root, policy) do
    with {:ok, settings} <- Handbean.WorkspaceSettings.load(workspace_root),
         :ok <- File.mkdir_p(Path.dirname(Handbean.WorkspaceSettings.path(workspace_root))) do
      settings
      |> Map.put("models", workspace_model_policy_to_json(policy))
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

  defp workspace_model_policy_to_json(%{mode: :unrestricted}) do
    %{"allow" => %{"providers" => %{}}}
  end

  defp workspace_model_policy_to_json(policy) do
    providers =
      policy.allowed
      |> Enum.reject(fn {_provider, models} -> MapSet.size(models) == 0 end)
      |> Map.new(fn {provider, models} ->
        {provider, %{"models" => models |> MapSet.to_list() |> Enum.sort()}}
      end)

    %{"allow" => %{"providers" => providers}}
    |> maybe_put_workspace_default(policy.default_model)
  end

  defp maybe_put_workspace_default(json, nil), do: json

  defp maybe_put_workspace_default(json, default_model) do
    case String.split(default_model, "/", parts: 2) do
      [provider, model] -> Map.put(json, "default", %{"provider" => provider, "model" => model})
      _ -> json
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
