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
  alias Handbean.Settings.Security
  alias Handbean.Agent.ModelConfig
  alias HandbeanWeb.Live.Settings.ComputerUsePanel
  alias HandbeanWeb.Live.Settings.ModelAIPanel
  alias HandbeanWeb.Live.Settings.WorkspaceModelsPanel

  @tabs [
    %{id: :model_ai, label_key: "Model / AI"},
    %{id: :workspace_models, label_key: "Workspace Models"},
    %{id: :workspace_memory, label_key: "Workspace Memory"},
    %{id: :available_models, label_key: "Available Models"},
    %{id: :local_webgpu, label_key: "Local WebGPU"},
    %{id: :computer_use, label_key: "Computer Control"},
    %{id: :plugins, label_key: "Plugins"},
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
    {secret_masking_enabled, secret_masking_error} = secret_masking_state()

    socket =
      socket
      |> assign(:page_title, gettext("Settings"))
      |> assign(:app_version, application_version())
      |> assign(:active_tab, active_tab)
      |> assign(:tabs, @tabs)
      |> assign(:workspaces, workspaces)
      |> assign(:workspace, workspace)
      |> assign(:return_workspace_id, workspace["id"])
      |> assign(:workspace_root, workspace_root)
      |> assign(:conversation_id, conversation_id)
      |> assign(:available_models, available_models)
      |> assign(:form, form)
      |> assign(:errors, %{})
      |> assign(:saving, false)
      |> assign(:toast, nil)
      |> assign(:runtime_banner, nil)
      |> assign(:speech_enabled, Handbean.Speech.enabled?())
      |> assign(:speech_supported, Handbean.Speech.supported?())
      |> assign(:speech_status, Handbean.Speech.status())
      |> assign(:speech_model, Handbean.Speech.model_info())
      |> assign(:secret_masking_enabled, secret_masking_enabled)
      |> assign(:secret_masking_error, secret_masking_error)
      |> WorkspaceModelsPanel.init(workspace_root)
      |> ComputerUsePanel.init()
      |> subscribe_to_runtime_tasks()
      |> subscribe_to_speech()

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
     |> WorkspaceModelsPanel.assign_context(workspace)}
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

  def handle_event(event, params, socket)
      when event in ~w(
             toggle_computer_use
             refresh_computer_use_status
             toggle_chrome_browser
             refresh_chrome_browser_status
           ),
      do: ComputerUsePanel.handle_event(event, params, socket)

  def handle_event("toggle_speech", _params, socket) do
    if speech_status_busy?(socket.assigns.speech_status) do
      {:noreply, socket}
    else
      enabled = not socket.assigns.speech_enabled

      case Handbean.Speech.set_enabled(enabled) do
        :ok when enabled ->
          {:noreply,
           socket
           |> assign(:speech_enabled, true)
           |> assign(:speech_status, :downloading)
           |> start_async(:prepare_speech, &Handbean.Speech.prepare/0)}

        :ok ->
          {:noreply,
           socket |> assign(:speech_enabled, false) |> assign(:speech_status, :disabled)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save voice input setting."))}
      end
    end
  end

  def handle_event("prepare_speech", _params, socket) do
    if socket.assigns.speech_enabled and socket.assigns.speech_supported and
         not speech_status_busy?(socket.assigns.speech_status) do
      {:noreply,
       socket
       |> assign(:speech_status, :downloading)
       |> start_async(:prepare_speech, &Handbean.Speech.prepare/0)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_secret_masking", _params, socket) do
    enabled = not socket.assigns.secret_masking_enabled

    case Security.set_secret_masking(enabled) do
      :ok ->
        {:noreply,
         socket
         |> assign(:secret_masking_enabled, enabled)
         |> assign(:secret_masking_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:secret_masking_error, reason)
         |> put_flash(:error, gettext("Could not save local secret masking setting."))}
    end
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

      if json != %{} or Map.has_key?(current, "advisor") or Map.has_key?(current, "subagent") or
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

  def handle_event(event, params, socket)
      when event in ~w(
             set_workspace_model_mode
             select_workspace_models
             filter_workspace_models
             set_workspace_provider_models
             toggle_workspace_model
             set_workspace_default_model
             save_workspace_models
           ),
      do: WorkspaceModelsPanel.handle_event(event, params, socket)

  def handle_async(:computer_use_status, result, socket),
    do: ComputerUsePanel.handle_async(:computer_use_status, result, socket)

  @impl true
  def handle_async(:prepare_speech, {:ok, :ok}, socket) do
    if socket.assigns.speech_enabled,
      do: {:noreply, assign(socket, :speech_status, :ready)},
      else: {:noreply, socket}
  end

  def handle_async(:prepare_speech, {:ok, {:error, reason}}, socket) do
    if socket.assigns.speech_enabled,
      do: {:noreply, assign(socket, :speech_status, {:error, reason})},
      else: {:noreply, socket}
  end

  def handle_async(:prepare_speech, {:exit, reason}, socket) do
    if socket.assigns.speech_enabled,
      do: {:noreply, assign(socket, :speech_status, {:error, reason})},
      else: {:noreply, socket}
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

  def handle_info({:computer_use_enabled, _enabled} = message, socket),
    do: ComputerUsePanel.handle_info(message, socket)

  def handle_info({:chrome_browser_enabled, _enabled} = message, socket),
    do: ComputerUsePanel.handle_info(message, socket)

  def handle_info({:chrome_browser_status, _status} = message, socket),
    do: ComputerUsePanel.handle_info(message, socket)

  def handle_info({:speech_enabled, enabled}, socket) do
    if socket.assigns.speech_enabled == enabled do
      {:noreply, socket}
    else
      status = if enabled, do: Handbean.Speech.status(), else: :disabled

      {:noreply,
       socket
       |> assign(:speech_enabled, enabled)
       |> assign(:speech_status, status)}
    end
  end

  def handle_info({:speech_status, status}, socket) do
    if socket.assigns.speech_enabled,
      do: {:noreply, assign(socket, :speech_status, status)},
      else: {:noreply, socket}
  end

  def handle_info({:in_app_ended, task, reason}, socket) do
    {:noreply,
     put_flash(socket, :info, HandbeanWeb.InAppNotification.ended_flash(task, reason, :navigate))}
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

  defp subscribe_to_speech(socket) do
    if connected?(socket) do
      Handbean.Speech.subscribe()
    end

    socket
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

  def tab_label(:model_ai), do: gettext("Model / AI")
  def tab_label(:workspace_models), do: gettext("Workspace Models")
  def tab_label(:workspace_memory), do: gettext("Workspace Memory")
  def tab_label(:available_models), do: gettext("Available Models")
  def tab_label(:local_webgpu), do: gettext("Advanced")
  def tab_label(:computer_use), do: gettext("Computer Control")
  def tab_label(:plugins), do: gettext("Plugins")
  def tab_label(:mcp), do: gettext("Plugins")
  def tab_label(:git), do: gettext("Git")
  def tab_label(:ui), do: gettext("UI")
  def tab_label(:sns), do: gettext("SNS")
  def tab_label(:tools), do: gettext("Tools")
  def tab_label(:security), do: gettext("Security")

  defp secret_masking_state do
    case Security.secret_masking_enabled?() do
      {:ok, enabled} -> {enabled, nil}
      {:error, reason} -> {false, reason}
    end
  end

  def tab_icon(:model_ai), do: "🧠"
  def tab_icon(:workspace_models), do: "▦"
  def tab_icon(:workspace_memory), do: "◉"
  def tab_icon(:available_models), do: "🔧"
  def tab_icon(:ui), do: "🎨"
  def tab_icon(:sns), do: "📡"
  def tab_icon(:tools), do: "🔒"
  def tab_icon(:security), do: "🛡️"

  defp application_version do
    case Application.spec(:handbean, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  def speech_status_label(_enabled, false, _status), do: gettext("Unavailable on this platform")
  def speech_status_label(false, true, _status), do: gettext("Off")
  def speech_status_label(true, true, :not_downloaded), do: gettext("Model not downloaded")
  def speech_status_label(true, true, :installed), do: gettext("Loading model…")
  def speech_status_label(true, true, :downloading), do: gettext("Downloading model…")
  def speech_status_label(true, true, :loading), do: gettext("Loading model…")
  def speech_status_label(true, true, :ready), do: gettext("Ready")
  def speech_status_label(true, true, :transcribing), do: gettext("Transcribing…")
  def speech_status_label(true, true, {:error, _reason}), do: gettext("Model setup failed")
  def speech_status_label(true, true, _status), do: gettext("Preparing…")

  def speech_status_busy?(status),
    do: status in [:installed, :downloading, :loading, :transcribing]

  def speech_status_retry?({:error, _reason}), do: true
  def speech_status_retry?(:not_downloaded), do: true
  def speech_status_retry?(_status), do: false

  def format_speech_model_size(bytes), do: HandbeanWeb.WorkspaceHelper.format_bytes(bytes)

  # ── Helpers ──

  defp theme_click(theme) do
    JS.set_attribute({"data-theme", theme}, to: "html")
    |> JS.push("set_theme", value: %{theme: theme})
  end

  defp tab_from_params(%{"tab" => "mcp"}), do: :plugins
  defp tab_from_params(%{"tab" => "plugins"}), do: :plugins

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

  defp update_form_field(form, "subagent_model", value) do
    case blank_to_nil(value) do
      nil ->
        struct!(form, subagent_mode: :inherit, subagent_model: nil, subagent_reasoning: nil)

      model ->
        struct!(form, subagent_mode: :custom, subagent_model: model, subagent_reasoning: nil)
    end
  end

  defp update_form_field(form, "subagent_reasoning", value) do
    struct!(form, subagent_reasoning: blank_to_nil(value))
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
end
