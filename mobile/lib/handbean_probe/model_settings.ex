defmodule HandbeanProbe.ModelSettings do
  @moduledoc """
  Native model configuration form, backed by Handbean's existing stores.

  Facade for `HandbeanProbe.HomeScreen`: owns the state shape, `load/2`, and the
  `action/3` dispatch. Logic lives in `HandbeanProbe.ModelSettings.Providers`
  (catalog CRUD and delete), `.Defaults` (scope, default model, reasoning),
  `.Memory` (observational memory fields), `.Policy` (workspace allowlist);
  nodes come from `.Render`, `.RenderForms`, `.RenderConfirm`.

  `load/2` and the reference scan read several files. `load_async/3` and
  `find_refs_async/4` run them under `HandbeanProbe.TaskSupervisor` for callers
  that must not block the screen process.
  """

  alias Handbean.Agent.ModelConfig
  alias Handbean.Settings.{ModelAIOverride, ModelAISettings, ModelPolicy, ModelRefs}

  alias HandbeanProbe.ModelSettings.{
    Defaults,
    Forms,
    Memory,
    Policy,
    Providers,
    Render,
    Subscriptions
  }

  alias HandbeanProbe.ModelSettings.RenderConfirm

  def empty do
    %{
      models: [],
      providers: [],
      selected_provider: nil,
      allowed_models: [],
      editing: nil,
      form: nil,
      default: nil,
      reasoning: ModelAISettings.defaults().reasoning,
      notice: nil,
      scope: :workspace,
      defaults: ModelAISettings.defaults(),
      sources: %{},
      policy: %{mode: :unrestricted, allowed: %{}, default_model: nil, configured?: false},
      confirm: nil,
      chat_blocked: nil,
      help_open: %{},
      select_open: nil,
      subscription_picker: false,
      subscription_login: nil,
      subscription_busy?: false,
      subscription_methods: Subscriptions.methods()
    }
  end

  def load(workspace, previous \\ nil) do
    path = workspace["path"]
    settings = Handbean.Settings.effective_model_ai(path)
    allowed = ModelConfig.available_models_for_workspace(path)
    providers = Providers.list()
    effective_default = settings.default_model || ModelConfig.default_model_for_workspace(path)

    %{
      empty()
      | models: ModelConfig.catalog_models(),
        providers: providers,
        selected_provider:
          Providers.pick_selected(providers, previous && previous.selected_provider),
        allowed_models: allowed,
        default: effective_default,
        reasoning: settings.reasoning,
        defaults: Defaults.form_for_scope(:workspace, workspace),
        sources: ModelAIOverride.sources(path),
        policy: ModelPolicy.form(path),
        chat_blocked: Policy.chat_blocked(path, allowed, effective_default),
        subscription_picker: previous && previous.subscription_picker,
        subscription_login: previous && previous.subscription_login,
        subscription_busy?: previous && previous.subscription_busy?,
        subscription_methods: Subscriptions.methods()
    }
  end

  @doc """
  `load/2` under `HandbeanProbe.TaskSupervisor`.

  Returns the `Task`; the caller receives `{ref, {:model_settings_loaded, generation, state}}`
  and the usual `:DOWN` message. Compare `generation` with the current one and drop
  stale results. Wiring into `HomeScreen` is WP7.
  """
  @spec load_async(map(), map() | nil, term()) :: Task.t()
  def load_async(workspace, previous, generation) do
    Task.Supervisor.async_nolink(HandbeanProbe.TaskSupervisor, fn ->
      {:model_settings_loaded, generation, load(workspace, previous)}
    end)
  end

  @doc """
  Reference scan for a delete under `HandbeanProbe.TaskSupervisor`.

  The caller receives `{ref, {:model_settings_refs, generation, {kind, provider, model}, result}}`
  and should feed `result` back through `action({:delete_refs_ready, kind, provider, model, result}, ...)`.
  `kind` is `:delete_model` or `:delete_provider`.
  """
  @spec find_refs_async(:delete_model | :delete_provider, String.t(), String.t() | nil, term()) ::
          Task.t()
  def find_refs_async(kind, provider, model, generation)
      when kind in [:delete_model, :delete_provider] do
    Task.Supervisor.async_nolink(HandbeanProbe.TaskSupervisor, fn ->
      result =
        case kind do
          :delete_model -> ModelRefs.find(:model, provider, model)
          :delete_provider -> ModelRefs.find(:provider, provider, nil)
        end

      {:model_settings_refs, generation, {kind, provider, model}, result}
    end)
  end

  @doc "Reload from disk keeping the current scope and showing `notice`."
  def reload(state, workspace, notice) do
    %{
      load(workspace, state)
      | scope: state.scope,
        defaults: Defaults.form_for_scope(state.scope, workspace),
        notice: notice
    }
  end

  def change(state, field, value) do
    cond do
      state.form && Map.has_key?(state.form, field) ->
        form = Map.put(state.form, field, value)
        %{state | form: Forms.hydrate(form, field, value)}

      field in [:om_max_recent_context] ->
        %{state | defaults: Map.put(state.defaults, field, value)}

      true ->
        state
    end
  end

  # ── dispatch ──

  def action({:scope, scope}, state, workspace) when scope in [:global, :workspace],
    do: Defaults.set_scope(state, scope, workspace)

  def action(:add_provider, state, _ws), do: Providers.add_provider(state)
  def action({:select_provider, provider}, state, _ws), do: Providers.select(state, provider)
  def action(:add_model, state, _ws), do: Providers.add_model(state)

  def action({:edit_model, provider, model}, state, _ws),
    do: Providers.edit_model(state, provider, model)

  def action({:edit_provider, provider}, state, _ws), do: Providers.edit_provider(state, provider)

  def action({:fetch_models, provider}, state, _ws) when is_binary(provider) do
    %{state | selected_provider: provider, confirm: nil}
  end

  def action({:catalog_model, model}, state, _ws), do: Providers.catalog_model(state, model)
  def action(:cancel_model, state, _ws), do: Providers.cancel(state)
  def action(:cancel_confirm, state, _ws), do: %{state | confirm: nil}

  def action({:toggle_help, key}, state, _ws) do
    open = state.help_open || %{}
    %{state | help_open: Map.put(open, key, !Map.get(open, key, false))}
  end

  def action({:toggle_select, id}, state, _ws) when is_binary(id) do
    next = if state.select_open == id, do: nil, else: id
    %{state | select_open: next}
  end

  def action({:api, api}, state, _ws), do: Providers.set_api(state, api)
  def action(:model_reasoning, state, _ws), do: Providers.toggle_reasoning(state)
  def action(:save_model, state, ws), do: Providers.save_model(state, ws)
  def action(:save_provider, state, ws), do: Providers.save_provider(state, ws)

  def action({:toggle_model_enabled, provider, model, enabled}, state, ws),
    do: Providers.toggle_enabled(state, provider, model, enabled, ws)

  def action({:ask_delete_model, provider, model}, state, _ws),
    do: Providers.ask_delete(state, :delete_model, provider, model)

  def action({:ask_delete_provider, provider}, state, _ws),
    do: Providers.ask_delete(state, :delete_provider, provider, nil)

  def action(
        {:delete_refs_ready, kind, provider, model, %{refs: _, errors: _} = result},
        state,
        _ws
      )
      when kind in [:delete_model, :delete_provider],
      do: Providers.delete_confirm(state, kind, provider, model, result)

  def action({:replacement, id}, state, _ws), do: Providers.set_replacement(state, id)
  def action(:confirm_delete, state, ws), do: Providers.confirm_delete(state, ws)

  def action({:default_model, model}, state, ws), do: Defaults.set_default_model(state, model, ws)
  def action({:reasoning, level}, state, ws), do: Defaults.set_reasoning(state, level, ws)
  def action({:inherit, field}, state, ws), do: Defaults.inherit(state, field, ws)
  def action(:inherit_all, state, ws), do: Defaults.inherit_all(state, ws)

  def action({:om_model, model}, state, ws), do: Memory.set_model(state, model, ws)
  def action({:om_memory_scope, scope}, state, ws), do: Memory.set_scope(state, scope, ws)
  def action({:om_privacy_mode, mode}, state, ws), do: Memory.set_privacy(state, mode, ws)
  def action(:save_memory_details, state, ws), do: Memory.save_details(state, ws)

  def action({:policy_mode, mode}, state, _ws), do: Policy.set_mode(state, mode)

  def action({:toggle_policy_model, provider, model}, state, _ws),
    do: Policy.toggle_model(state, provider, model)

  def action({:policy_default, model}, state, _ws), do: Policy.set_default(state, model)
  def action(:save_policy, state, ws), do: Policy.save(state, ws)

  def action(:open_subscription_login, state, _ws) do
    %{
      state
      | subscription_picker: true,
        subscription_login: nil,
        notice: nil,
        subscription_methods: Subscriptions.methods()
    }
  end

  def action(:close_subscription_login, state, _ws) do
    %{state | subscription_picker: false}
  end

  def action(:cancel_subscription_login, state, _ws) do
    %{state | subscription_picker: false, subscription_login: nil, subscription_busy?: false}
  end

  def action({:subscription_started, session}, state, _ws) when is_map(session) do
    %{
      state
      | subscription_picker: false,
        subscription_busy?: false,
        subscription_login: Subscriptions.public_session(session),
        notice: nil
    }
  end

  def action({:subscription_failed, message}, state, _ws) when is_binary(message) do
    %{
      state
      | subscription_picker: false,
        subscription_login: nil,
        subscription_busy?: false,
        notice: message
    }
  end

  def action({:subscription_waiting, public_device}, state, _ws) when is_map(public_device) do
    case state.subscription_login do
      %{} = login ->
        code = public_device[:user_code] || login.user_code
        %{state | subscription_login: %{login | user_code: code}}

      _ ->
        state
    end
  end

  def action(_unknown, state, _workspace), do: state

  # ── render ──

  def render(state), do: Render.render(state)

  def confirm_sheet(state), do: RenderConfirm.confirm_sheet(state)
end
