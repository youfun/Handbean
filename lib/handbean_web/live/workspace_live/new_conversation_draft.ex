defmodule HandbeanWeb.WorkspaceLive.NewConversationDraft do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Handbean.Permissions.ConversationMode
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching.CheckoutMetadata
  alias HandbeanWeb.WorkspaceLive.ModelSelection

  @permission_modes [:prompt, :auto_review, :yolo]

  @free_workspace_id "__free__"

  def open(socket, opts \\ []) do
    source = Keyword.get(opts, :source, :header)
    workspace_id = Keyword.get(opts, :workspace_id) || default_workspace_id(socket)

    case build(socket, workspace_id, source) do
      {:ok, draft} -> assign(socket, :new_conversation_draft, draft)
      {:error, message} -> assign(socket, :composer_error, message)
    end
  end

  def open_free(socket, opts \\ []) do
    source = Keyword.get(opts, :source, :sidebar)
    {:ok, draft} = build_free_draft(socket, source)
    assign(socket, :new_conversation_draft, draft)
  end

  def free_draft?(%{workspace_id: @free_workspace_id}), do: true
  def free_draft?(_draft), do: false

  def close(socket), do: assign(socket, :new_conversation_draft, nil)

  def toggle(socket) do
    if socket.assigns[:new_conversation_draft] do
      close(socket)
    else
      open(socket)
    end
  end

  def toggle_projects(socket) do
    update_draft(socket, fn draft ->
      %{draft | project_menu_open?: not draft.project_menu_open?}
    end)
  end

  def select_workspace(socket, workspace_id) when is_binary(workspace_id) do
    current = socket.assigns[:new_conversation_draft]

    with %{} <- current,
         {:ok, draft} <- build(socket, workspace_id, current.source) do
      draft = %{
        draft
        | id: current.id,
          message: current.message,
          project_menu_open?: false
      }

      assign(socket, :new_conversation_draft, draft)
    else
      _ -> put_error(socket, gettext("找不到工作区"))
    end
  end

  def select_workspace(socket, _workspace_id), do: socket

  def select_checkout(socket, checkout_path) when is_binary(checkout_path) do
    update_draft(socket, fn draft ->
      if Enum.any?(draft.checkouts, &(&1.path == checkout_path)) do
        %{draft | checkout_path: checkout_path, error: nil}
      else
        %{draft | error: gettext("所选 checkout 已不可用，请重新选择")}
      end
    end)
  end

  def select_checkout(socket, _checkout_path), do: socket

  def update(socket, params) when is_map(params) do
    update_draft(socket, fn draft ->
      draft
      |> maybe_put_message(params)
      |> maybe_put_checkout(params)
      |> maybe_put_model(params)
      |> maybe_put_reasoning(params)
      |> maybe_put_permission(params)
      |> Map.put(:error, nil)
    end)
  end

  def prepare_submit(socket, params) when is_map(params) do
    socket = update(socket, params)

    submitted_id = params["draft_id"]

    case socket.assigns[:new_conversation_draft] do
      %{id: ^submitted_id} = draft -> validate_submit(socket, draft)
      %{} -> {:error, put_error(socket, gettext("新对话草稿已过期，请重试"))}
      nil -> {:error, socket}
    end
  end

  def apply_model_selection(socket, draft) do
    socket =
      if free_draft?(draft),
        do: ModelSelection.reload_free_models(socket),
        else: ModelSelection.initialize_workspace_conversation_model(socket)

    socket
    |> assign(:selected_model, draft.model)
    |> assign(:model_selection_revision, 0)
    |> ModelSelection.sync_reasoning_for_model(draft.model)
    |> assign(:selected_reasoning_level, draft.reasoning)
  end

  defp build(socket, workspace_id, source) do
    projects = CheckoutMetadata.new_conversation_projects(socket.assigns[:workspaces] || [])

    case Enum.find(projects, &(&1.id == workspace_id)) do
      nil ->
        {:error, gettext("找不到工作区")}

      project ->
        models = model_defaults(socket, project)
        checkout_path = default_checkout_path(socket, project)
        permission_mode = default_permission_mode(socket, workspace_id)

        {:ok,
         %{
           id: Ecto.UUID.generate(),
           source: source,
           projects: projects,
           project_menu_open?: false,
           workspace_id: project.id,
           workspace_name: project.name,
           workspace_path: project.path,
           checkouts: project.checkouts,
           checkout_path: checkout_path,
           models: models.available_models,
           model: models.selected_model,
           reasoning_levels: models.available_reasoning_levels,
           reasoning: models.selected_reasoning_level,
           permission_mode: permission_mode,
           message: "",
           error: nil
         }}
    end
  end

  defp build_free_draft(socket, source) do
    models = free_model_defaults(socket)
    permission_mode = default_free_permission_mode()

    {:ok,
     %{
       id: Ecto.UUID.generate(),
       source: source,
       projects: [],
       project_menu_open?: false,
       workspace_id: @free_workspace_id,
       workspace_name: gettext("自由对话"),
       workspace_path: nil,
       checkouts: [],
       checkout_path: nil,
       models: models.available_models,
       model: models.selected_model,
       reasoning_levels: models.available_reasoning_levels,
       reasoning: models.selected_reasoning_level,
       permission_mode: permission_mode,
       message: "",
       error: nil
     }}
  end

  defp free_model_defaults(socket) do
    available = Handbean.Agent.ModelConfig.all_global_models()
    settings = Handbean.Settings.global_model_ai()

    selected =
      cond do
        is_binary(settings.default_model) and
            Enum.any?(available, &(&1.id == settings.default_model)) ->
          settings.default_model

        is_binary(socket.assigns[:selected_model]) and
            Enum.any?(available, &(&1.id == socket.assigns[:selected_model])) ->
          socket.assigns[:selected_model]

        true ->
          available |> List.first() |> then(&if(&1, do: &1.id))
      end

    entry = ModelSelection.model_entry_for(selected, available)
    levels = Handbean.Agent.Reasoning.supported_levels(entry)

    reasoning =
      if settings.reasoning in levels,
        do: settings.reasoning,
        else: Handbean.Agent.Reasoning.default_level(entry)

    %{
      available_models: available,
      selected_model: selected,
      available_reasoning_levels: levels,
      selected_reasoning_level: reasoning
    }
  end

  defp default_free_permission_mode() do
    case ConversationMode.mode_for_create("free", nil, []) do
      {:ok, mode} -> String.to_existing_atom(mode)
      {:error, _reason} -> ConversationMode.default()
    end
  end

  defp validate_submit(socket, draft) do
    message = String.trim(draft.message)

    if free_draft?(draft) do
      validate_free_submit(socket, draft, message)
    else
      validate_workspace_submit(socket, draft, message)
    end
  end

  defp validate_workspace_submit(socket, draft, message) do
    with :ok <- require_content(socket, message),
         {:ok, workspace} <- Handbean.WorkspaceStore.refresh_identity(draft.workspace_id),
         {:ok, checkout_path} <- validate_checkout(workspace, draft.checkout_path),
         {:ok, models, model} <- validate_model(workspace, draft.model),
         {:ok, reasoning_levels, reasoning} <-
           validate_reasoning(models, model, draft.reasoning),
         {:ok, permission_mode} <- validate_permission(draft.permission_mode) do
      validated = %{
        draft
        | message: message,
          workspace_path: workspace["path"],
          checkout_path: checkout_path,
          models: models,
          model: model,
          reasoning_levels: reasoning_levels,
          reasoning: reasoning,
          permission_mode: permission_mode,
          error: nil
      }

      {:ok, assign(socket, :new_conversation_draft, validated), validated}
    else
      {:error, message} -> {:error, put_error(socket, message)}
    end
  end

  defp validate_free_submit(socket, draft, message) do
    model_root = draft.workspace_path

    with :ok <- require_content(socket, message),
         {:ok, models, model} <- validate_free_model(model_root, draft.model),
         {:ok, reasoning_levels, reasoning} <-
           validate_reasoning(models, model, draft.reasoning),
         {:ok, permission_mode} <- validate_permission(draft.permission_mode) do
      validated = %{
        draft
        | message: message,
          models: models,
          model: model,
          reasoning_levels: reasoning_levels,
          reasoning: reasoning,
          permission_mode: permission_mode,
          error: nil
      }

      {:ok, assign(socket, :new_conversation_draft, validated), validated}
    else
      {:error, message} -> {:error, put_error(socket, message)}
    end
  end

  defp validate_free_model(nil, model) do
    validate_free_model("", model)
  end

  defp validate_free_model(_model_root, model) do
    models = Handbean.Agent.ModelConfig.all_global_models()

    cond do
      models == [] ->
        {:error, gettext("没有可用模型")}

      Enum.any?(models, &(&1.id == model)) ->
        {:ok, models, model}

      true ->
        {:error, gettext("所选模型已不可用，请重新选择")}
    end
  end

  defp require_content(socket, "") do
    if Composer.has_upload_entries?(socket),
      do: :ok,
      else: {:error, gettext("请输入消息或添加图片")}
  end

  defp require_content(_socket, _message), do: :ok

  defp validate_checkout(workspace, checkout_path) do
    checkouts = CheckoutMetadata.checkouts_for(workspace)

    case Enum.find(checkouts, &(&1.path == checkout_path)) do
      %{path: path} -> {:ok, path}
      nil -> {:error, gettext("所选 checkout 已不可用，请重新选择")}
    end
  end

  defp validate_model(workspace, model) do
    models = Handbean.Agent.ModelConfig.available_models_for_workspace(workspace["path"])

    cond do
      models == [] ->
        {:error, gettext("此工作区没有可用模型")}

      Enum.any?(models, &(&1.id == model)) ->
        {:ok, models, model}

      true ->
        {:error, gettext("所选模型已不可用，请重新选择")}
    end
  end

  defp validate_reasoning(models, model, reasoning) do
    entry = ModelSelection.model_entry_for(model, models)
    levels = Handbean.Agent.Reasoning.supported_levels(entry)

    cond do
      levels == [] and reasoning in [nil, "", "off"] ->
        {:ok, levels, reasoning}

      reasoning in levels ->
        {:ok, levels, reasoning}

      true ->
        {:error, gettext("所选推理等级已不可用，请重新选择")}
    end
  end

  defp validate_permission(permission_mode) do
    case ConversationMode.normalize(permission_mode) do
      {:ok, mode} when mode in @permission_modes -> {:ok, mode}
      _ -> {:error, gettext("所选权限模式无效")}
    end
  end

  defp maybe_put_message(draft, %{"message" => message}) when is_binary(message),
    do: %{draft | message: message}

  defp maybe_put_message(draft, _params), do: draft

  defp maybe_put_checkout(draft, %{"checkout_path" => checkout_path})
       when is_binary(checkout_path),
       do: %{draft | checkout_path: checkout_path}

  defp maybe_put_checkout(draft, _params), do: draft

  defp maybe_put_model(draft, %{"model" => model}) when is_binary(model) do
    entry = ModelSelection.model_entry_for(model, draft.models)
    levels = Handbean.Agent.Reasoning.supported_levels(entry)
    reasoning = Handbean.Agent.Reasoning.default_level(entry)

    %{draft | model: model, reasoning_levels: levels, reasoning: reasoning}
  end

  defp maybe_put_model(draft, _params), do: draft

  defp maybe_put_reasoning(draft, %{"reasoning" => reasoning}) when is_binary(reasoning) do
    %{draft | reasoning: reasoning}
  end

  defp maybe_put_reasoning(draft, _params), do: draft

  defp maybe_put_permission(draft, %{"permission_mode" => mode}) when is_binary(mode) do
    case ConversationMode.normalize(mode) do
      {:ok, normalized} -> %{draft | permission_mode: normalized}
      {:error, _reason} -> %{draft | permission_mode: mode}
    end
  end

  defp maybe_put_permission(draft, _params), do: draft

  defp model_defaults(socket, project) do
    boot = ModelSelection.boot(project.path)
    effective = Handbean.Settings.effective_model_ai(project.path)

    selected =
      cond do
        is_binary(effective.default_model) and
            Enum.any?(boot.available_models, &(&1.id == effective.default_model)) ->
          effective.default_model

        socket.assigns[:current_workspace_id] == project.id and
            Enum.any?(boot.available_models, &(&1.id == socket.assigns[:selected_model])) ->
          socket.assigns.selected_model

        true ->
          boot.selected_model
      end

    entry = ModelSelection.model_entry_for(selected, boot.available_models)
    levels = Handbean.Agent.Reasoning.supported_levels(entry)

    reasoning =
      cond do
        effective.reasoning in levels ->
          effective.reasoning

        socket.assigns[:current_workspace_id] == project.id and
            socket.assigns[:selected_reasoning_level] in levels ->
          socket.assigns.selected_reasoning_level

        true ->
          Handbean.Agent.Reasoning.default_level(entry)
      end

    %{
      available_models: boot.available_models,
      selected_model: selected,
      available_reasoning_levels: levels,
      selected_reasoning_level: reasoning
    }
  end

  defp default_workspace_id(socket) do
    current = socket.assigns[:current_workspace_id]
    workspaces = socket.assigns[:workspaces] || []

    if Enum.any?(workspaces, &(&1["id"] == current)) do
      current
    else
      workspaces |> List.first() |> then(&if(&1, do: &1["id"]))
    end
  end

  defp default_checkout_path(socket, project) do
    current_path = socket.assigns[:workspace_root]

    cond do
      socket.assigns[:current_workspace_id] == project.id and
          Enum.any?(project.checkouts, &(&1.path == current_path)) ->
        current_path

      checkout = Enum.find(project.checkouts, & &1.main?) ->
        checkout.path

      checkout = List.first(project.checkouts) ->
        checkout.path

      true ->
        project.path
    end
  end

  defp default_permission_mode(socket, workspace_id) do
    opts =
      if socket.assigns[:current_workspace_id] == workspace_id and
           is_binary(socket.assigns[:current_conversation_id]) do
        [inherit_from: socket.assigns.current_conversation_id]
      else
        []
      end

    case ConversationMode.mode_for_create("workspace", workspace_id, opts) do
      {:ok, mode} -> String.to_existing_atom(mode)
      {:error, _reason} -> ConversationMode.default()
    end
  end

  defp update_draft(socket, fun) do
    case socket.assigns[:new_conversation_draft] do
      %{} = draft -> assign(socket, :new_conversation_draft, fun.(draft))
      nil -> socket
    end
  end

  defp put_error(socket, message) do
    update_draft(socket, &%{&1 | error: message})
  end
end
