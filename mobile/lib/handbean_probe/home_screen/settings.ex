defmodule HandbeanProbe.HomeScreen.Settings do
  @moduledoc """
  Model / AI settings as seen by the screen.

  Reading the effective settings (`ModelSettings.load/2`) and scanning model
  references before a delete (`ModelSettings.find_refs_async/4`) run under
  `HandbeanProbe.TaskSupervisor`; their task refs are registered under the
  `:models` scope of `HandbeanProbe.PendingRequests` (`HomeScreen.Requests`),
  so a stale reply is dropped before it reaches this module, and a loaded
  result is also dropped when an unsaved form is open. Subscription device
  login uses the same table under `:subscription_login`: start, poll, persist,
  and catalog discovery are tasks, and the next poll is armed with
  `{:pending_request_timeout, ref}`. Cancel bumps that scope so a late poll is
  dropped. Copy uses `Mob.Clipboard.put/2`. Opening the verification link uses
  `Platform.open_url/4`.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import Mob.Socket, only: [assign: 3]

  alias Handbean.ArtifactDelivery.Url
  alias HandbeanProbe.HomeScreen.{Async, Notice, Requests}
  alias HandbeanProbe.ModelSettings
  alias HandbeanProbe.ModelSettings.Subscriptions
  alias HandbeanProbe.Platform

  @scope :models
  @subscription_scope :subscription_login

  @settings_pages [:models, :settings]

  # ── dispatch ──

  def handle({:tap, {:composer_setting, field, value}}, socket)
      when field in [:default_model, :reasoning] do
    workspace = socket.assigns.workspace

    models =
      socket.assigns.models
      |> ModelSettings.Defaults.set_scope(:workspace, workspace)
      |> then(&ModelSettings.action({field, value}, &1, workspace))

    socket
    |> assign(:models, models)
    |> assign(:composer_select, nil)
    |> HandbeanProbe.HomeScreen.Notice.put_info(models.notice)
    |> HandbeanProbe.NativeModelInputs.check()
  end

  def handle({:change, {:model_field, field}, value}, socket) do
    assign(socket, :models, ModelSettings.change(socket.assigns.models, field, value))
  end

  def handle({:change, {:toggle_model_enabled, provider, model, _current}, enabled}, socket)
      when is_boolean(enabled) do
    action(socket, {:toggle_model_enabled, provider, model, enabled})
  end

  def handle({:dismiss, :cancel_confirm}, socket), do: action(socket, :cancel_confirm)

  def handle({:tap, {:ask_delete_model, provider, model}}, socket),
    do: find_refs(socket, :delete_model, provider, model)

  def handle({:tap, {:ask_delete_provider, provider}}, socket),
    do: find_refs(socket, :delete_provider, provider, nil)

  def handle({:tap, {:start_subscription, provider_id}}, socket) when is_binary(provider_id),
    do: start_subscription(socket, provider_id)

  def handle({:tap, :open_subscription_link}, socket), do: open_subscription_link(socket)

  def handle({:tap, {:copy_subscription, field}}, socket)
      when field in [:verification_uri, :user_code],
      do: copy_subscription(socket, field)

  def handle({:tap, :cancel_subscription_login}, socket) do
    {_generation, socket} = Requests.bump(socket, @subscription_scope)
    action(socket, :cancel_subscription_login)
  end

  def handle({:tap, {:fetch_models, provider}}, socket) when is_binary(provider) do
    fetch_models(socket, provider)
  end

  def handle({:tap, :save_provider}, socket) do
    socket = action(socket, :save_provider)
    maybe_fetch_after_save(socket)
  end

  def handle({:tap, action}, socket), do: action(socket, action)

  def handle({:models_updated}, socket) do
    # Do not replace an unsaved form when another entry point updates models.
    if not is_nil(socket.assigns.models.form) or is_nil(socket.assigns.workspace),
      do: socket,
      else: load_models(socket)
  end

  def settings_page?(page), do: page in @settings_pages

  # ── async ──

  @doc "Reload effective model settings off-screen for the current workspace."
  def load_models(%{assigns: %{workspace: nil}} = socket), do: socket

  def load_models(socket) do
    {generation, socket} = Requests.bump(socket, @scope)
    task = ModelSettings.load_async(socket.assigns.workspace, socket.assigns.models, generation)

    Requests.register(socket, task.ref, :model_settings_loaded,
      scope: @scope,
      generation: generation
    )
  end

  # A form opened while loading owns the state; keep what the user is editing.
  def handle_loaded(socket, models) do
    if socket.assigns.models.form,
      do: socket,
      else: socket |> assign(:models, models) |> HandbeanProbe.NativeModelInputs.check()
  end

  def handle_refs(socket, {kind, provider, model}, result),
    do: action(socket, {:delete_refs_ready, kind, provider, model, result})

  def handle_subscription(:subscription_started, {:ok, session}, socket) do
    socket
    |> action({:subscription_started, session})
    |> schedule_subscription_poll(session.device, session.interval_ms)
  end

  def handle_subscription(:subscription_started, {:error, message}, socket) do
    action(socket, {:subscription_failed, message})
  end

  def handle_subscription(
        :subscription_polled,
        {:continue, _status, public_device, interval_ms, device},
        socket
      ) do
    socket
    |> action({:subscription_waiting, public_device})
    |> schedule_subscription_poll(device, interval_ms)
  end

  def handle_subscription(:subscription_polled, {:authorized, credential}, socket) do
    persist_subscription(socket, socket.assigns[:subscription_provider_id], credential)
  end

  def handle_subscription(:subscription_polled, {:error, message}, socket) do
    action(socket, {:subscription_failed, message})
  end

  def handle_subscription(
        :subscription_authorized,
        {:ok, %{provider_id: provider_id, generation: generation}},
        socket
      ) do
    discover_subscription(socket, provider_id, generation)
  end

  def handle_subscription(:subscription_authorized, {:error, message}, socket) do
    action(socket, {:subscription_failed, message})
  end

  def handle_subscription(:subscription_discovered, :ok, socket) do
    provider_id = socket.assigns[:subscription_provider_id]

    socket
    |> assign(:subscription_provider_id, nil)
    |> action(:cancel_subscription_login)
    |> Notice.put_info(Subscriptions.connected_message(provider_id))
    |> load_models()
  end

  def handle_subscription(:models_fetched, result, socket) do
    socket
    |> assign(:models, %{socket.assigns.models | notice: nil})
    |> apply_fetched_models(result)
  end

  def handle_subscription(:subscription_discovered, {:error, message}, socket) do
    socket
    |> assign(:subscription_provider_id, nil)
    |> action({:subscription_failed, message})
  end

  def handle_subscription(_kind, _result, socket), do: socket

  defp maybe_fetch_after_save(socket) do
    models = socket.assigns.models
    provider_id = models.selected_provider
    provider = Enum.find(models.providers, &(&1.id == provider_id))

    cond do
      models.notice != gettext("Provider saved") ->
        socket

      match?(%{fetchable: true}, provider) ->
        fetch_models(socket, provider_id)

      provider_id in ["openai_codex", "cursor"] ->
        fetch_subscription_catalog(socket, provider_id)

      true ->
        socket
    end
  end

  defp fetch_subscription_catalog(socket, provider_id) do
    {generation, socket} = Requests.bump(socket, @scope)

    task =
      Task.Supervisor.async_nolink(HandbeanProbe.TaskSupervisor, fn ->
        {:models_fetched, generation, refresh_subscription_catalog(provider_id)}
      end)

    socket
    |> assign(:models, %{socket.assigns.models | notice: gettext("Fetching models…")})
    |> Requests.register(task.ref, :models_fetched, scope: @scope, generation: generation)
  end

  defp refresh_subscription_catalog(provider_id) do
    generation = Handbean.Agent.Auth.Epoch.current(provider_id)

    case Subscriptions.discover(provider_id, generation) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp catalog_discover_opts do
    case Application.get_env(:handbean, :catalog_req_module) do
      module when is_atom(module) and not is_nil(module) -> [req_module: module]
      _ -> []
    end
  end

  defp fetch_models(socket, provider_id) do
    {generation, socket} = Requests.bump(socket, @scope)
    opts = catalog_discover_opts()

    task =
      Task.Supervisor.async_nolink(HandbeanProbe.TaskSupervisor, fn ->
        {:models_fetched, generation,
         Handbean.Agent.Provider.ModelCatalog.discover(provider_id, opts)}
      end)

    socket
    |> action({:fetch_models, provider_id})
    |> assign(:models, %{socket.assigns.models | notice: gettext("Fetching models…")})
    |> Requests.register(task.ref, :models_fetched, scope: @scope, generation: generation)
  end

  defp apply_fetched_models(socket, :ok) do
    socket
    |> load_models()
    |> Notice.put_info(gettext("Provider saved"))
  end

  defp apply_fetched_models(socket, {:ok, %{added: added, total: total}}) do
    socket
    |> load_models()
    |> Notice.put_info(
      gettext("Fetched %{total} models, %{added} new", total: total, added: added)
    )
  end

  defp apply_fetched_models(socket, {:error, message}) when is_binary(message) do
    Notice.put_error(socket, message)
  end

  defp apply_fetched_models(socket, _result) do
    Notice.put_error(socket, gettext("Model discovery failed"))
  end

  defp start_subscription(socket, provider_id) do
    {_generation, socket} = Requests.bump(socket, @subscription_scope)

    socket =
      socket
      |> assign(:subscription_provider_id, provider_id)
      |> assign(:models, %{socket.assigns.models | subscription_busy?: true, notice: nil})

    Async.run(socket, :subscription_started, fn -> Subscriptions.start(provider_id) end,
      scope: @subscription_scope,
      bump?: false
    )
  end

  # The private device session lives on the pending-request ctx, not in
  # assigns. The deadline message starts the next poll so the screen never
  # sleeps or calls the network itself.
  defp schedule_subscription_poll(socket, device, interval_ms) when is_map(device) do
    provider_id = socket.assigns[:subscription_provider_id]
    ref = make_ref()

    Requests.register(socket, ref, :subscription_poll_due,
      scope: @subscription_scope,
      timeout_ms: max(interval_ms, 0),
      ctx: %{provider_id: provider_id, device: device}
    )
  end

  def poll_due(socket, %{provider_id: provider_id, device: device})
      when is_binary(provider_id) and is_map(device) do
    Async.run(socket, :subscription_polled, fn -> Subscriptions.poll(provider_id, device) end,
      scope: @subscription_scope,
      bump?: false
    )
  end

  def poll_due(socket, _ctx), do: socket

  defp persist_subscription(socket, provider_id, credential) when is_binary(provider_id) do
    Async.run(
      socket,
      :subscription_authorized,
      fn -> Subscriptions.persist(provider_id, credential) end,
      scope: @subscription_scope,
      bump?: false
    )
  end

  defp persist_subscription(socket, _provider_id, _credential) do
    action(socket, {:subscription_failed, Subscriptions.hint(nil)})
  end

  defp discover_subscription(socket, provider_id, generation) do
    Async.run(
      socket,
      :subscription_discovered,
      fn -> Subscriptions.discover(provider_id, generation) end,
      scope: @subscription_scope,
      bump?: false
    )
  end

  defp open_subscription_link(socket) do
    case subscription_field(socket, :verification_uri) do
      uri when is_binary(uri) ->
        case Url.parse(uri) do
          {:ok, parsed} ->
            request_id = Ecto.UUID.generate()
            generation = Requests.composer_generation(socket)

            case Platform.open_url(self(), request_id, generation, parsed) do
              {:ok, _} ->
                Requests.track(socket, request_id, :open_url, %{url: parsed})

              {:error, reason} ->
                Notice.put_error(socket, open_url_error(reason))
            end

          {:error, _reason} ->
            Notice.put_error(socket, gettext("Could not open the verification link."))
        end

      _ ->
        socket
    end
  end

  defp copy_subscription(socket, field) do
    case subscription_field(socket, field) do
      text when is_binary(text) and text != "" ->
        socket = Subscriptions.copy(socket, text)
        Notice.put_info(socket, copied_notice(field))

      _ ->
        socket
    end
  end

  defp subscription_field(socket, field) do
    login = socket.assigns.models.subscription_login
    login && Map.get(login, field)
  end

  defp copied_notice(:verification_uri), do: gettext("Verification link copied")
  defp copied_notice(:user_code), do: gettext("User code copied")

  defp open_url_error(reason) when is_binary(reason), do: reason
  defp open_url_error(_reason), do: gettext("Could not open the verification link.")

  defp find_refs(socket, kind, provider, model) do
    generation = Requests.generation(socket, @scope)
    task = ModelSettings.find_refs_async(kind, provider, model, generation)

    Requests.register(socket, task.ref, :model_settings_refs,
      scope: @scope,
      generation: generation
    )
  end

  defp action(socket, action) do
    models = ModelSettings.action(action, socket.assigns.models, socket.assigns.workspace)
    models = close_select(models, action)

    socket
    |> assign(:models, models)
    |> HandbeanProbe.NativeModelInputs.check()
  end

  defp close_select(models, {:toggle_select, _}), do: models
  defp close_select(models, {:toggle_help, _}), do: models
  defp close_select(models, _), do: %{models | select_open: nil}
end
