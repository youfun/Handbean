defmodule HandbeanWeb.WorkspaceLive.ModelSelection do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Handbean.Agent.{RunOpts, Runner}
  alias Handbean.Settings
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.StatusProjection

  require Logger

  def state_opts do
    [
      model_display_name: &model_display_name/2,
      sync_reasoning_for_conversation: &sync_reasoning_for_conversation/3,
      update_status: &StatusProjection.maybe_update_status/2,
      load_effective_settings: &load_effective_settings/1
    ]
  end

  def switching_opts do
    state_opts()
    |> Keyword.take([:model_display_name, :update_status])
    |> Keyword.put(:initialize_model, &initialize_conversation_model/1)
  end

  def boot(workspace_root) do
    _ = Handbean.Agent.ModelConfig.ensure_config()
    available = Handbean.Agent.ModelConfig.available_models_for_workspace(workspace_root)

    selected =
      Handbean.Agent.ModelConfig.default_model_for_workspace(workspace_root) ||
        (List.first(available) && List.first(available).id)

    entry = model_entry_for(selected, available)

    %{
      available_models: available,
      selected_model: selected,
      selected_reasoning_level: Handbean.Agent.Reasoning.default_level(entry),
      available_reasoning_levels: Handbean.Agent.Reasoning.supported_levels(entry),
      status_model: model_display_name(selected, available)
    }
  end

  def select(socket, model) do
    socket
    |> assign_model(model)
    |> ConversationState.sync_conv_to()
    |> request_active_switch()
  end

  def select_reasoning(socket, level) do
    selected =
      if level in socket.assigns.available_reasoning_levels,
        do: level,
        else: socket.assigns.selected_reasoning_level

    socket
    |> assign(:selected_reasoning_level, selected)
    |> ConversationState.sync_conv_to()
    |> request_active_switch()
  end

  def select_from_sheet(socket, model) do
    socket
    |> select(model)
    |> assign(:show_model_sheet, false)
  end

  def select_reasoning_from_sheet(socket, level) do
    socket
    |> select_reasoning(level)
    |> assign(:show_reasoning_sheet, false)
  end

  def refresh(socket), do: reload_workspace_models(socket)

  def apply_submitted(socket, params) do
    socket
    |> maybe_assign_submitted_model(params)
    |> maybe_assign_submitted_reasoning(params)
  end

  def apply_command(socket, message) do
    {command?, remaining, model} = parse_model_command(message)

    socket = if command?, do: assign_model(socket, model), else: socket
    message = if command? and is_nil(remaining), do: "", else: remaining || message
    {socket, message}
  end

  def apply_effective(socket), do: apply_effective_model_ai_settings(socket)

  defp assign_model(socket, model) do
    display = model_display_name(model, socket.assigns.available_models)

    overrides =
      if Map.get(socket.assigns, :running, false) do
        %{future_model: display}
      else
        %{model: display, active_model: display, future_model: display, pending_model: nil}
      end

    socket
    |> assign(:selected_model, model)
    |> sync_reasoning_for_model(model)
    |> StatusProjection.update_status(overrides)
  end

  def maybe_assign_submitted_model(socket, %{"model" => model}) when is_binary(model) do
    if Enum.any?(socket.assigns.available_models, &(&1.id == model)) do
      socket
      |> assign(:selected_model, model)
      |> sync_reasoning_for_model(model)
    else
      socket
    end
  end

  def maybe_assign_submitted_model(socket, _params), do: socket

  def maybe_assign_submitted_reasoning(socket, %{"reasoning" => reasoning})
      when is_binary(reasoning) do
    if reasoning in socket.assigns.available_reasoning_levels do
      assign(socket, :selected_reasoning_level, reasoning)
    else
      socket
    end
  end

  def maybe_assign_submitted_reasoning(socket, _params), do: socket

  def reload_free_models(socket) do
    available = Handbean.Agent.ModelConfig.all_global_models()
    settings = Handbean.Settings.global_model_ai()

    selected =
      cond do
        settings.default_model && Enum.any?(available, &(&1.id == settings.default_model)) ->
          settings.default_model

        socket.assigns.selected_model &&
            Enum.any?(available, &(&1.id == socket.assigns.selected_model)) ->
          socket.assigns.selected_model

        true ->
          available |> List.first() |> then(&if(&1, do: &1.id))
      end

    socket
    |> assign(:available_models, available)
    |> assign(:selected_model, selected)
    |> assign(:effective_settings, settings)
    |> sync_reasoning_for_model(selected)
    |> update_selected_status(model_display_name(selected, available))
  end

  def reload_workspace_models(socket) do
    if ConversationState.free_chat?(socket) do
      reload_free_models(socket)
    else
      reload_workspace_models_for_path(socket)
    end
  end

  def reload_workspace_models_for_path(socket) do
    workspace_root =
      case Handbean.WorkspaceStore.get(socket.assigns.current_workspace_id) do
        {:ok, ws} -> ws["path"]
        {:error, _} -> Handbean.Workspace.root()
      end

    available = Handbean.Agent.ModelConfig.available_models_for_workspace(workspace_root)

    current_model = socket.assigns.selected_model

    selected =
      if current_model && Enum.any?(available, &(&1.id == current_model)) do
        current_model
      else
        nil
      end

    socket
    |> assign(:available_models, available)
    |> assign(:selected_model, selected)
    |> sync_reasoning_for_model(selected)
    |> update_selected_status(model_display_name(selected, available))
    |> maybe_sync_selected_model_to_conversation()
  end

  def reload_workspace_counts(socket) do
    if ConversationState.free_chat?(socket) do
      assign(socket, :mcp_count, 0) |> assign(:skills_count, 0)
    else
      reload_workspace_counts_for_path(socket)
    end
  end

  def reload_workspace_counts_for_path(socket) do
    workspace_root = ConversationState.current_workspace_path(socket)
    checkout_root = ConversationState.current_checkout_path(socket)

    mcp_count =
      case Handbean.MCP.ConfigLoader.load(project: workspace_root) do
        {:ok, config} -> map_size(config.servers)
      end

    skills_count =
      if is_binary(checkout_root),
        do: length(Handbean.Skills.Loader.load(workspace: checkout_root).skills),
        else: 0

    socket
    |> assign(:mcp_count, mcp_count)
    |> assign(:skills_count, skills_count)
  end

  def sync_reasoning_for_model(socket, model_id) do
    model_entry = model_entry_for(model_id, socket.assigns.available_models)
    levels = Handbean.Agent.Reasoning.supported_levels(model_entry)
    current = Map.get(socket.assigns, :selected_reasoning_level)

    selected =
      if current in levels do
        current
      else
        Handbean.Agent.Reasoning.default_level(model_entry)
      end

    socket
    |> assign(:available_reasoning_levels, levels)
    |> assign(:selected_reasoning_level, selected)
  end

  def sync_reasoning_for_conversation(socket, conv, model_id) do
    model_entry = model_entry_for(model_id, Map.get(socket.assigns, :available_models, []))
    levels = Handbean.Agent.Reasoning.supported_levels(model_entry)
    stored = ConversationState.conv_value(conv, "selected_reasoning_level", nil)

    selected =
      if stored in levels do
        stored
      else
        Handbean.Agent.Reasoning.default_level(model_entry)
      end

    socket
    |> assign(:available_reasoning_levels, levels)
    |> assign(:selected_reasoning_level, selected)
  end

  def maybe_sync_selected_model_to_conversation(socket) do
    conv = ConversationState.current_conv_map(socket)

    if ConversationState.conv_value(conv, "selected_model", nil) == socket.assigns.selected_model do
      socket
    else
      ConversationState.sync_conv_to(socket)
    end
  end

  def model_entry_for(nil, _available), do: %{}

  def model_entry_for(composite_id, available) do
    Enum.find(available, &(&1.id == composite_id || Map.get(&1, :model_id) == composite_id)) ||
      %{}
  end

  def model_display_name(nil, _available), do: "None"

  def model_display_name(composite_id, available) do
    case Enum.find(available, &(&1.id == composite_id || Map.get(&1, :model_id) == composite_id)) do
      nil ->
        composite_id

      %{provider_id: provider_id} = entry ->
        siblings = Enum.filter(available, &(&1.provider_id == entry.provider_id))
        "#{provider_display_name(provider_id)} / #{model_option_label(entry, siblings)}"

      %{display_name: display_name} ->
        display_name
    end
  end

  def models_by_provider(models) do
    models
    |> Enum.group_by(& &1.provider_id)
    |> Enum.sort_by(fn {provider_id, _models} -> provider_display_name(provider_id) end)
  end

  def provider_display_name(nil), do: "Unknown"
  def provider_display_name(provider_id), do: provider_id

  def model_option_label(model, models \\ []) do
    name = label_name(model)

    case distinguishing_label(model, name, models) do
      nil -> name
      suffix -> "#{name} #{suffix}"
    end
  end

  def label_name(model) do
    cond do
      is_binary(model.name) and model.name != "" -> model.name
      is_binary(model.model_id) and model.model_id != "" -> model.model_id
      true -> model.id
    end
  end

  def distinguishing_label(model, name, models) do
    id = model_identity(model)

    collisions =
      Enum.filter(models, fn other ->
        label_name(other) == name and model_identity(other) != id
      end)

    if collisions == [] do
      nil
    else
      tokens = id_tokens(id)

      extra =
        Enum.reject(tokens, fn token ->
          Enum.all?(collisions, &(token in id_tokens(model_identity(&1))))
        end)

      cond do
        extra == [] -> nil
        extra == tokens -> "(#{id_tail(id)})"
        true -> Enum.map_join(extra, " ", &humanize_id_token/1)
      end
    end
  end

  def model_identity(model) do
    if is_binary(model.model_id) and model.model_id != "", do: model.model_id, else: model.id
  end

  def id_tail(id) do
    id |> to_string() |> String.split("/") |> List.last()
  end

  def id_tokens(id) do
    id_tail(id)
    |> String.split("-")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
  end

  def humanize_id_token("fast"), do: "Fast"
  def humanize_id_token("max"), do: "Max"
  def humanize_id_token("thinking"), do: "Thinking"
  def humanize_id_token("1m"), do: "1M"
  def humanize_id_token(token), do: String.capitalize(token)

  def model_empty_message(workspace_root) do
    case Handbean.Agent.ModelConfig.global_config_status() do
      :ok ->
        case Handbean.Agent.ModelConfig.load_workspace_policy(workspace_root) do
          {:ok, _policy} -> "No allowed models configured for this workspace"
          {:error, _reason} -> "Workspace model policy is invalid"
          :unrestricted -> "Configure models before sending"
        end

      {:error, _reason} ->
        "Configure models before sending"
    end
  end

  def parse_model_command(message) when is_binary(message) do
    case String.split(message, ~r/\s+/, parts: 3) do
      ["/model", model_id] ->
        {true, nil, model_id}

      ["/model", model_id, rest] ->
        {true, rest, model_id}

      _ ->
        {false, nil, nil}
    end
  end

  def load_effective_settings(socket) do
    if ConversationState.free_chat?(socket) do
      assign(socket, :effective_settings, Handbean.Settings.global_model_ai())
    else
      load_workspace_effective_settings(socket)
    end
  end

  def load_workspace_effective_settings(socket) do
    workspace_path = ConversationState.current_workspace_path(socket)

    if is_nil(workspace_path) or workspace_path == "" do
      Logger.warning(
        "[WorkspaceLive] load_effective_settings: workspace_path is nil/empty, skipping"
      )

      assign(socket, :effective_settings, Handbean.Settings.ModelAISettings.defaults())
    else
      case Settings.fetch_effective_model_ai(workspace_path) do
        {:ok, effective} ->
          assign(socket, :effective_settings, effective)

        {:error, reason} ->
          Logger.error("[WorkspaceLive] load_effective_settings failed: #{inspect(reason)}")
          assign(socket, :effective_settings, Handbean.Settings.ModelAISettings.defaults())
      end
    end
  end

  def initialize_conversation_model(socket) do
    if ConversationState.free_chat?(socket) do
      reload_free_models(socket)
    else
      initialize_workspace_conversation_model(socket)
    end
  end

  def initialize_workspace_conversation_model(socket) do
    workspace_path = ConversationState.current_workspace_path(socket)
    available = Handbean.Agent.ModelConfig.available_models_for_workspace(workspace_path)

    socket
    |> assign(:available_models, available)
    |> load_effective_settings()
    |> apply_effective_model_ai_settings()
  end

  def apply_effective_model_ai_settings(socket) do
    effective = socket.assigns.effective_settings
    available = socket.assigns.available_models

    selected_model =
      cond do
        effective && effective.default_model &&
            Enum.any?(available, &(&1.id == effective.default_model)) ->
          effective.default_model

        socket.assigns.selected_model &&
            Enum.any?(available, &(&1.id == socket.assigns.selected_model)) ->
          socket.assigns.selected_model

        true ->
          socket.assigns.selected_model
      end

    socket = assign(socket, :selected_model, selected_model)

    socket =
      if effective && effective.reasoning do
        levels =
          Handbean.Agent.Reasoning.supported_levels(model_entry_for(selected_model, available))

        if effective.reasoning in levels do
          socket
          |> assign(:available_reasoning_levels, levels)
          |> assign(:selected_reasoning_level, effective.reasoning)
        else
          sync_reasoning_for_model(socket, selected_model)
        end
      else
        sync_reasoning_for_model(socket, selected_model)
      end

    update_selected_status(socket, model_display_name(selected_model, available))
  end

  def effective_model_and_reasoning(socket) do
    effective = socket.assigns[:effective_settings]

    model =
      cond do
        socket.assigns.selected_model ->
          socket.assigns.selected_model

        effective && effective.default_model ->
          effective.default_model

        true ->
          nil
      end

    # Conversation picker wins. Global settings only fill in when this
    # conversation has not chosen a level yet. Amp cannot switch mid-thread;
    # Handbean can, so the composer value must reach the next turn.
    reasoning =
      cond do
        is_binary(socket.assigns[:selected_reasoning_level]) and
            socket.assigns.selected_reasoning_level != "" ->
          socket.assigns.selected_reasoning_level

        effective && effective.reasoning ->
          effective.reasoning

        true ->
          Handbean.Settings.ModelAISettings.defaults().reasoning
      end

    {model, reasoning}
  end

  def om_from_effective(nil), do: []

  def om_from_effective(effective) do
    opts = Handbean.Settings.ModelAISettings.to_runtime_opts(effective)
    [om: Keyword.get(opts, :om, %{enabled: false})]
  end

  defp update_selected_status(socket, display) do
    if Map.get(socket.assigns, :running, false) do
      StatusProjection.update_status(socket, %{future_model: display})
    else
      StatusProjection.update_status(socket, %{
        model: display,
        active_model: display,
        future_model: display,
        pending_model: nil
      })
    end
  end

  defp request_active_switch(socket) do
    conversation_id = socket.assigns[:current_conversation_id]

    if socket.assigns[:running] and is_binary(conversation_id) do
      with {:ok, %{running?: true, run_id: run_id}} <- Runner.status(conversation_id),
           {workspace_path, effective} <- switch_settings(socket),
           {:ok, run_opts} <-
             RunOpts.for_selection(
               workspace_path,
               socket.assigns.selected_model,
               socket.assigns.selected_reasoning_level,
               effective
             ),
           {:ok, _accepted} <-
             Runner.request_model_switch(conversation_id, run_id, %{
               model_ref: socket.assigns.selected_model,
               reasoning_level: socket.assigns.selected_reasoning_level,
               run_opts: run_opts
             }) do
        socket
      else
        {:ok, %{running?: false}} -> socket
        {:error, reason} when reason in [:not_found, :not_running] -> socket
        {:error, {:run_mismatch, _current}} -> socket
        {:error, reason} -> model_switch_error(socket, reason)
      end
    else
      socket
    end
  end

  defp switch_settings(socket) do
    if ConversationState.free_chat?(socket) do
      {nil, Settings.global_model_ai()}
    else
      path = ConversationState.current_workspace_path(socket)
      {path, Settings.effective_model_ai(path)}
    end
  end

  defp model_switch_error(socket, reason) do
    Logger.warning("[ModelSelection] active-run model switch rejected: #{inspect(reason)}")

    StatusProjection.update_status(socket, %{
      status_detail: "Model switch failed: #{inspect(reason)}"
    })
  end

  def resolve_selected_model(_workspace_path, nil),
    do: {:error, "Configure models before sending"}

  def resolve_selected_model(workspace_path, selected_model) do
    Handbean.Agent.RunOpts.resolve_model(workspace_path, selected_model)
  end

  defdelegate resolve_global_model(selected_model), to: Handbean.Agent.ModelConfig

  def resolve_auto_title_model(socket, _conv) do
    workspace_path = ConversationState.current_workspace_path(socket)

    # Use the resolved model from socket assigns (which may have fallen back
    # to an available model), not the raw conversation store value.
    model_id = socket.assigns[:selected_model]

    case resolve_selected_model(workspace_path, model_id) do
      {:ok, provider_config, _resolved_id} ->
        {:ok, provider_config, model_id}

      {:error, reason} ->
        {:error, reason, model_id}
    end
  end
end
