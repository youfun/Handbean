defmodule HandbeanWeb.AvailableModelsLive do
  use HandbeanWeb, :live_view

  alias Handbean.Agent.Auth.{
    CodexCredential,
    CodexOAuth,
    CursorCredential,
    CursorOAuth,
    Epoch,
    Storage,
    Subscriptions,
    XaiOAuth
  }

  alias Handbean.Agent.Provider.Codex.Models, as: CodexModels
  alias Handbean.Agent.Provider.Cursor.Models, as: CursorModels
  alias Handbean.Agent.Provider.ModelCatalog
  alias Handbean.Agent.ModelConfig
  alias HandbeanWeb.AvailableModelsLive.{Forms, Presentation, Projection}

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Handbean.PubSub, "models:updated")

    ModelConfig.ensure_config()
    config = Projection.load_raw_config()
    providers = Projection.parse_providers(config)
    embedded = Map.get(session, "embedded") == "true"
    selected_id = if embedded, do: nil, else: Map.get(config, "defaultProvider", "")

    socket =
      socket
      |> assign(:catalog_price_generation, 0)
      |> assign(:page_title, gettext("设置 / 可用模型"))
      |> assign(:embedded, embedded)
      |> assign(:config, config)
      |> assign(:providers, providers)
      |> assign(:selected_provider_id, selected_id)
      |> assign(:selected_provider, Projection.find_provider(selected_id, providers))
      |> assign(:show_add_provider, false)
      |> assign(:show_edit_provider, false)
      |> assign(:show_add_model, false)
      |> assign(:show_delete_confirm, false)
      |> assign(:delete_target, nil)
      |> assign(:add_provider_form, Forms.reset_add_provider())
      |> assign(:edit_provider_form, %{})
      |> assign(:add_model_form, Forms.reset_add_model())
      |> assign(:form_error, nil)
      |> assign(:toast, nil)
      |> assign(:xai_oauth, nil)
      |> assign(:subscription_oauth, nil)
      |> assign(:codex_discover_attempt, nil)
      |> assign(:cursor_discover_attempt, nil)
      |> assign(:catalog_discover_attempt, nil)
      |> assign(:show_subscription_login, false)
      |> assign(:subscription_methods, Subscriptions.methods())
      |> schedule_catalog_prices(providers)

    {:ok, socket}
  end

  @impl true
  def handle_info({:models_updated}, socket) do
    config = Projection.load_raw_config()
    providers = Projection.parse_providers(config)
    selected_id = Projection.maybe_reselect(socket.assigns.selected_provider_id, providers)

    socket =
      socket
      |> assign(:config, config)
      |> assign(:providers, providers)
      |> assign(:selected_provider_id, selected_id)
      |> assign(:selected_provider, Projection.find_provider(selected_id, providers))
      |> schedule_catalog_prices(providers)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_toast, socket) do
    {:noreply, assign(socket, :toast, nil)}
  end

  def handle_info(:poll_xai_oauth, socket) do
    {:noreply, poll_subscription_oauth(socket)}
  end

  def handle_info({:poll_subscription_oauth, attempt_id}, socket) do
    {:noreply, poll_subscription_oauth(socket, attempt_id)}
  end

  @impl true
  def handle_async({:subscription_oauth_poll, attempt_id}, {:ok, result}, socket) do
    {:noreply, handle_async_poll(socket, attempt_id, result)}
  end

  def handle_async({:subscription_oauth_poll, attempt_id}, {:exit, _reason}, socket) do
    {:noreply,
     handle_async_poll(socket, attempt_id, {:error, gettext("Subscription authorization failed")})}
  end

  def handle_async({:codex_models, attempt_id, generation}, {:ok, result}, socket) do
    {:noreply, apply_codex_models(socket, attempt_id, generation, result)}
  end

  def handle_async({:codex_models, attempt_id, generation}, {:exit, _reason}, socket) do
    {:noreply,
     apply_codex_models(
       socket,
       attempt_id,
       generation,
       {:error, gettext("Model discovery failed")}
     )}
  end

  def handle_async({:cursor_models, attempt_id}, {:ok, result}, socket) do
    {:noreply, apply_cursor_models(socket, attempt_id, result)}
  end

  def handle_async({:cursor_models, attempt_id}, {:exit, _reason}, socket) do
    {:noreply,
     apply_cursor_models(socket, attempt_id, {:error, gettext("Model discovery failed")})}
  end

  def handle_async({:provider_models, attempt_id}, {:ok, result}, socket) do
    {:noreply, apply_provider_models(socket, attempt_id, result)}
  end

  def handle_async({:provider_models, attempt_id}, {:exit, _reason}, socket) do
    {:noreply,
     apply_provider_models(socket, attempt_id, {:error, gettext("Model discovery failed")})}
  end

  def handle_async({:catalog_prices, generation}, {:ok, prices}, socket) do
    if socket.assigns.catalog_price_generation == generation do
      providers = Projection.apply_catalog_prices(socket.assigns.providers, prices)

      {:noreply,
       socket
       |> assign(:providers, providers)
       |> assign(
         :selected_provider,
         Projection.find_provider(socket.assigns.selected_provider_id, providers)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:catalog_prices, _generation}, {:exit, _reason}, socket),
    do: {:noreply, socket}

  def handle_event("open_subscription_login", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_subscription_login, true)
     |> assign(:form_error, nil)}
  end

  def handle_event("close_subscription_login", _params, socket) do
    {:noreply, assign(socket, :show_subscription_login, false)}
  end

  def handle_event("start_subscription_oauth", %{"id" => provider_id}, socket) do
    {:noreply, start_subscription_oauth(socket, provider_id)}
  end

  def handle_event("cancel_xai_oauth", _params, socket) do
    {:noreply, clear_subscription_oauth(socket)}
  end

  def handle_event("cancel_subscription_oauth", _params, socket) do
    {:noreply, clear_subscription_oauth(socket)}
  end

  def handle_event("refresh_codex_models", _params, socket) do
    {:noreply, maybe_discover_codex_models(socket, "openai_codex")}
  end

  def handle_event("refresh_cursor_models", _params, socket) do
    attempt_id = System.unique_integer([:positive])
    {:noreply, maybe_discover_cursor_models(socket, "cursor", attempt_id)}
  end

  def handle_event("refresh_provider_models", _params, socket) do
    {:noreply, discover_provider_models(socket)}
  end

  def handle_event("disable_all_models", _params, socket) do
    provider_id = socket.assigns.selected_provider_id

    case ModelConfig.disable_provider_models(provider_id) do
      :ok ->
        {:noreply, reload_providers(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, reason)}
    end
  end

  def handle_event("toggle_model_enabled", %{"id" => model_id}, socket) do
    provider_id = socket.assigns.selected_provider_id
    # Checkbox clicks drop phx-value-value after the first row. Flip the stored
    # flag instead of requiring the browser to send the next state.
    enabled =
      not Projection.model_enabled?(socket.assigns.providers, provider_id, model_id)

    case ModelConfig.update_model(provider_id, model_id, %{"enabled" => enabled}) do
      :ok ->
        {:noreply, reload_providers(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, reason)}
    end
  end

  @impl true
  def handle_event("select_provider", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider_id, id)
     |> assign(:selected_provider, Projection.find_provider(id, socket.assigns.providers))}
  end

  def handle_event("clear_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider_id, nil)
     |> assign(:selected_provider, nil)}
  end

  @impl true
  def handle_event("toggle_default_provider", %{"id" => id}, socket) when is_binary(id) do
    case ModelConfig.set_default_provider(id) do
      :ok ->
        toast = %{
          type: :success,
          message: gettext("默认供应商已更改"),
          id: System.unique_integer([:positive])
        }

        Process.send_after(self(), :clear_toast, 3000)
        {:noreply, socket |> assign(:toast, toast) |> assign(:form_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, reason)}
    end
  end

  def handle_event("toggle_default_provider", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("Invalid provider selection"))}
  end

  @impl true
  def handle_event("open_add_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_provider, true)
     |> assign(:form_error, nil)
     |> assign(:add_provider_form, Forms.reset_add_provider())}
  end

  def handle_event("close_add_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_provider, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("update_add_provider", %{"add_provider" => params}, socket) do
    previous = socket.assigns.add_provider_form
    form = Forms.merge_add_provider(previous, params)
    {:noreply, assign(socket, :add_provider_form, form)}
  end

  def handle_event("update_add_provider", _params, socket) do
    # Form change with partial params (e.g., only _target)
    {:noreply, socket}
  end

  def handle_event("submit_add_provider", %{"add_provider" => params}, socket) do
    case Forms.add_provider_submission(
           socket.assigns.add_provider_form,
           params,
           socket.assigns.providers
         ) do
      {:error, :provider_id_empty} ->
        {:noreply, assign(socket, :form_error, gettext("Provider ID 不能为空"))}

      {:error, :provider_id_invalid} ->
        {:noreply, assign(socket, :form_error, gettext("Provider ID 只能包含小写字母、数字、横线和下划线"))}

      {:ok, provider_id, provider_attrs} ->
        case ModelConfig.add_provider(provider_id, provider_attrs) do
          :ok ->
            toast = %{
              type: :success,
              message: gettext("供应商已成功添加"),
              id: System.unique_integer([:positive])
            }

            Process.send_after(self(), :clear_toast, 3000)

            {:noreply,
             socket
             |> assign(:show_add_provider, false)
             |> assign(:form_error, nil)
             |> assign(:add_provider_form, Forms.reset_add_provider())
             |> assign(:selected_provider_id, provider_id)
             |> reload_providers()
             |> maybe_refresh_saved_catalog(provider_id)
             |> assign(:toast, toast)}

          {:error, reason} ->
            {:noreply, assign(socket, :form_error, reason)}
        end
    end
  end

  def handle_event("submit_add_provider", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  @impl true
  def handle_event("open_edit_provider", %{"id" => id}, socket) do
    provider = Projection.find_provider(id, socket.assigns.providers)

    {:noreply,
     socket
     |> assign(:show_edit_provider, true)
     |> assign(:form_error, nil)
     |> assign(:edit_provider_form, Forms.edit_provider_form(provider))}
  end

  def handle_event("close_edit_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_provider, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("update_edit_provider", %{"edit_provider" => params}, socket) do
    form = Map.merge(socket.assigns.edit_provider_form, params)
    {:noreply, assign(socket, :edit_provider_form, form)}
  end

  def handle_event("update_edit_provider", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("submit_edit_provider", %{"edit_provider" => params}, socket) do
    provider_id = socket.assigns.selected_provider_id
    attrs = Forms.edit_provider_attrs(socket.assigns.edit_provider_form, params)

    case ModelConfig.update_provider(provider_id, attrs) do
      :ok ->
        toast = %{
          type: :success,
          message: gettext("供应商已成功更新"),
          id: System.unique_integer([:positive])
        }

        Process.send_after(self(), :clear_toast, 3000)

        {:noreply,
         socket
         |> assign(:show_edit_provider, false)
         |> assign(:form_error, nil)
         |> reload_providers()
         |> maybe_refresh_saved_catalog(provider_id)
         |> assign(:toast, toast)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, reason)}
    end
  end

  def handle_event("submit_edit_provider", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  @impl true
  def handle_event("confirm_delete_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, true)
     |> assign(:delete_target, %{type: :provider, id: socket.assigns.selected_provider_id})}
  end

  def handle_event("confirm_delete_model", %{"id" => model_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, true)
     |> assign(:delete_target, %{
       type: :model,
       provider_id: socket.assigns.selected_provider_id,
       model_id: model_id
     })}
  end

  def handle_event("close_delete_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, false)
     |> assign(:delete_target, nil)}
  end

  def handle_event("execute_delete", _params, socket) do
    target = socket.assigns.delete_target

    result =
      case target do
        %{type: :provider, id: id} -> ModelConfig.remove_provider(id)
        %{type: :model, provider_id: pid, model_id: mid} -> ModelConfig.remove_model(pid, mid)
        _ -> {:error, "无效的删除目标"}
      end

    case result do
      :ok ->
        toast = %{
          type: :success,
          message: gettext("已成功删除"),
          id: System.unique_integer([:positive])
        }

        Process.send_after(self(), :clear_toast, 3000)

        {:noreply,
         socket
         |> assign(:show_delete_confirm, false)
         |> assign(:delete_target, nil)
         |> assign(:toast, toast)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_delete_confirm, false)
         |> assign(:delete_target, nil)
         |> assign(:form_error, reason)}
    end
  end

  def handle_event("open_add_model", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_model, true)
     |> assign(:form_error, nil)
     |> assign(:add_model_form, Forms.reset_add_model())}
  end

  def handle_event("close_add_model", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_model, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("update_add_model", %{"add_model" => params}, socket) do
    form = Map.merge(socket.assigns.add_model_form, params)
    {:noreply, assign(socket, :add_model_form, form)}
  end

  def handle_event("update_add_model", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("submit_add_model", %{"add_model" => params}, socket) do
    provider_id = socket.assigns.selected_provider_id

    case Forms.add_model_submission(socket.assigns.add_model_form, params, provider_id) do
      {:error, :model_id_empty} ->
        {:noreply, assign(socket, :form_error, gettext("模型 ID 不能为空"))}

      {:ok, model_id, model_attrs} ->
        case ModelConfig.add_model(provider_id, model_id, model_attrs) do
          :ok ->
            toast = %{
              type: :success,
              message: gettext("模型已成功添加"),
              id: System.unique_integer([:positive])
            }

            Process.send_after(self(), :clear_toast, 3000)

            {:noreply,
             socket
             |> assign(:show_add_model, false)
             |> assign(:form_error, nil)
             |> assign(:add_model_form, Forms.reset_add_model())
             |> reload_providers()
             |> assign(:toast, toast)}

          {:error, reason} ->
            {:noreply, assign(socket, :form_error, reason)}
        end
    end
  end

  def handle_event("submit_add_model", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, :form_error, nil)}
  end

  defp start_subscription_oauth(socket, provider_id) do
    socket = clear_subscription_oauth(socket)

    with {:ok, method} <- Subscriptions.get(provider_id),
         :ok <- ensure_subscription_provider(method),
         {:ok, device} <- start_device_flow(method) do
      attempt_id = System.unique_integer([:positive])
      schedule_subscription_poll(device, attempt_id)

      socket
      |> assign(:show_subscription_login, false)
      |> reload_providers()
      |> assign(:selected_provider_id, method.id)
      |> assign(
        :selected_provider,
        Projection.find_provider(
          method.id,
          Projection.parse_providers(Projection.load_raw_config())
        )
      )
      |> assign(:form_error, nil)
      |> put_oauth(%{
        provider_id: method.id,
        login_label: method.login_label,
        device: device,
        verification_uri: verification_uri(method.id, device),
        status: :waiting,
        hint: oauth_hint(method.id),
        attempt_id: attempt_id,
        polling?: false
      })
    else
      {:error, message} ->
        socket
        |> assign(:show_subscription_login, false)
        |> assign(:form_error, message)
    end
  end

  defp start_device_flow(%{id: "xai"}), do: XaiOAuth.start()
  defp start_device_flow(%{id: "openai_codex"}), do: CodexOAuth.start()
  defp start_device_flow(%{id: "cursor"}), do: CursorOAuth.start()

  defp start_device_flow(%{id: id}),
    do: {:error, "Subscription login for #{id} is not implemented yet"}

  defp verification_uri("xai", device), do: XaiOAuth.browser_verification_uri(device)
  defp verification_uri("openai_codex", device), do: CodexOAuth.browser_verification_uri(device)
  defp verification_uri("cursor", device), do: CursorOAuth.browser_verification_uri(device)

  defp oauth_hint("openai_codex"),
    do: gettext("打开下面的链接，输入用户码完成 ChatGPT 授权。使用 Codex 订阅额度，不是 OpenAI API 余额；可用模型与限额由账号决定。")

  defp oauth_hint("cursor"),
    do: gettext("打开下面的链接，用 Cursor 账号完成浏览器授权。这是非官方协议接入，费用未知，不会显示为免费。")

  defp oauth_hint(_), do: gettext("打开下面的链接，输入用户码完成 xAI 订阅授权。")

  defp poll_subscription_oauth(socket, attempt_id \\ nil)

  defp poll_subscription_oauth(
         %{assigns: %{subscription_oauth: %{device: device} = oauth}} = socket,
         attempt_id
       ) do
    if oauth.polling? or (attempt_id && attempt_id != oauth.attempt_id) do
      socket
    else
      socket
      |> start_async({:subscription_oauth_poll, oauth.attempt_id}, fn ->
        poll_once(oauth.provider_id, device)
      end)
      |> put_oauth(%{oauth | polling?: true})
    end
  end

  defp poll_subscription_oauth(socket, _attempt_id), do: socket

  defp poll_once("xai", device), do: XaiOAuth.poll_once(device)
  defp poll_once("openai_codex", device), do: CodexOAuth.poll_once(device)
  defp poll_once("cursor", device), do: CursorOAuth.poll_once(device)

  defp handle_async_poll(
         %{assigns: %{subscription_oauth: %{attempt_id: attempt_id} = oauth}} = socket,
         attempt_id,
         result
       ) do
    case result do
      {status, updated} when status in [:pending, :slow_down] ->
        schedule_subscription_poll(updated, attempt_id)
        put_oauth(socket, %{oauth | device: updated, polling?: false})

      {:authorized, credential} ->
        persist_authorized(socket, oauth, credential)

      {:error, message} ->
        socket |> clear_subscription_oauth() |> assign(:form_error, message)
    end
  end

  defp handle_async_poll(socket, _attempt_id, _result), do: socket

  defp persist_authorized(socket, oauth, credential) do
    result =
      case oauth.provider_id do
        "openai_codex" -> CodexCredential.store_login(oauth.provider_id, credential)
        "cursor" -> CursorCredential.store_login(oauth.provider_id, credential)
        provider_id -> Storage.put(provider_id, credential)
      end

    case result do
      :ok ->
        Process.send_after(self(), :clear_toast, 3000)

        message =
          case oauth.provider_id do
            "openai_codex" -> "已连接 ChatGPT / Codex 订阅"
            "cursor" -> "已连接 Cursor 订阅（非官方协议，费用未知）"
            _ -> "已连接 xAI / Grok 订阅"
          end

        socket
        |> clear_subscription_oauth()
        |> assign(:toast, %{
          type: :success,
          message: message,
          id: System.unique_integer([:positive])
        })
        |> reload_providers()
        |> maybe_discover_codex_models(oauth.provider_id)
        |> maybe_discover_cursor_models(oauth.provider_id, oauth.attempt_id)
        |> maybe_discover_subscription_models(oauth.provider_id)

      {:error, message} ->
        socket |> clear_subscription_oauth() |> assign(:form_error, message)
    end
  end

  defp maybe_discover_codex_models(socket, "openai_codex") do
    attempt_id = System.unique_integer([:positive])
    generation = Epoch.current("openai_codex")

    socket
    |> cancel_discovery_async(:codex)
    |> start_async({:codex_models, attempt_id, generation}, fn -> CodexModels.discover() end)
    |> assign(:codex_discover_attempt, {attempt_id, generation})
  end

  defp maybe_discover_codex_models(socket, _), do: socket

  defp maybe_discover_cursor_models(socket, "cursor", attempt_id) do
    socket
    |> cancel_discovery_async(:cursor)
    |> start_async({:cursor_models, attempt_id}, fn -> CursorModels.discover() end)
    |> assign(:cursor_discover_attempt, attempt_id)
  end

  defp maybe_discover_cursor_models(socket, _provider_id, _attempt_id), do: socket

  defp maybe_discover_subscription_models(socket, "xai"), do: discover_provider_models(socket)
  defp maybe_discover_subscription_models(socket, _provider_id), do: socket

  defp discover_provider_models(socket) do
    provider_id = socket.assigns.selected_provider_id
    attempt_id = System.unique_integer([:positive])
    opts = Projection.catalog_discover_opts()

    socket
    |> cancel_discovery_async(:provider)
    |> start_async({:provider_models, attempt_id}, fn ->
      ModelCatalog.discover(provider_id, opts)
    end)
    |> assign(:catalog_discover_attempt, attempt_id)
  end

  # Saving a provider is the same as asking for its catalog. OAuth subscriptions
  # use their own discovery; every other fetchable provider uses the shared list.
  defp maybe_refresh_saved_catalog(socket, provider_id) do
    provider =
      case Projection.load_raw_config() do
        %{"providers" => %{^provider_id => provider}} -> provider
        _ -> nil
      end

    cond do
      provider_id == "openai_codex" ->
        maybe_discover_codex_models(socket, provider_id)

      provider_id == "cursor" ->
        maybe_discover_cursor_models(
          socket,
          provider_id,
          System.unique_integer([:positive])
        )

      is_map(provider) and ModelCatalog.fetchable?(provider) ->
        discover_provider_models(socket)

      true ->
        socket
    end
  end

  defp apply_provider_models(socket, attempt_id, result) do
    if socket.assigns[:catalog_discover_attempt] == attempt_id do
      socket = assign(socket, :catalog_discover_attempt, nil)

      case result do
        {:ok, %{added: added, total: total}} ->
          Process.send_after(self(), :clear_toast, 3000)

          socket
          |> reload_providers()
          |> assign(:toast, %{
            type: :success,
            message: gettext("Fetched %{total} models, %{added} new", total: total, added: added),
            id: System.unique_integer([:positive])
          })

        {:error, message} ->
          assign(socket, :form_error, message)
      end
    else
      socket
    end
  end

  defp apply_cursor_models(socket, attempt_id, result) do
    current = socket.assigns[:cursor_discover_attempt]

    if is_nil(current) or current != attempt_id do
      socket
    else
      socket = assign(socket, :cursor_discover_attempt, nil)

      case result do
        {:ok, models} ->
          models =
            ModelCatalog.refresh_merge(Projection.stored_models("cursor"), models, missing: :drop)

          case ModelConfig.update_provider("cursor", %{"models" => models}) do
            :ok -> reload_providers(socket)
            {:error, message} -> assign(socket, :form_error, message)
          end

        {:error, message} ->
          assign(socket, :form_error, message)
      end
    end
  end

  defp apply_codex_models(socket, attempt_id, generation, result) do
    if socket.assigns.codex_discover_attempt == {attempt_id, generation} and
         Epoch.current("openai_codex") == generation do
      socket = assign(socket, :codex_discover_attempt, nil)

      case result do
        {:ok, models} ->
          models =
            CodexModels.preserve_enabled(models, Projection.stored_models("openai_codex"))

          case ModelConfig.update_provider("openai_codex", %{"models" => models}) do
            :ok -> reload_providers(socket)
            {:error, message} -> assign(socket, :form_error, message)
          end

        {:error, message} ->
          assign(socket, :form_error, message)
      end
    else
      socket
    end
  end

  defp put_oauth(socket, oauth) do
    socket |> assign(:subscription_oauth, oauth) |> assign(:xai_oauth, oauth)
  end

  defp clear_subscription_oauth(socket) do
    socket
    |> cancel_subscription_poll()
    |> cancel_discovery_async(:codex)
    |> cancel_discovery_async(:cursor)
    |> put_oauth(nil)
    |> assign(:codex_discover_attempt, nil)
    |> assign(:cursor_discover_attempt, nil)
    |> assign(:catalog_discover_attempt, nil)
  end

  defp cancel_discovery_async(socket, :codex) do
    case socket.assigns[:codex_discover_attempt] do
      nil -> socket
      {attempt_id, generation} -> cancel_async(socket, {:codex_models, attempt_id, generation})
    end
  end

  defp cancel_discovery_async(socket, :cursor) do
    case socket.assigns[:cursor_discover_attempt] do
      nil -> socket
      attempt_id -> cancel_async(socket, {:cursor_models, attempt_id})
    end
  end

  defp cancel_discovery_async(socket, :provider) do
    case socket.assigns[:catalog_discover_attempt] do
      nil -> socket
      attempt_id -> cancel_async(socket, {:provider_models, attempt_id})
    end
  end

  defp cancel_subscription_poll(socket) do
    case socket.assigns.subscription_oauth do
      %{attempt_id: attempt_id, polling?: true} ->
        cancel_async(socket, {:subscription_oauth_poll, attempt_id})

      _ ->
        socket
    end
  end

  defp schedule_subscription_poll(device, attempt_id) do
    Process.send_after(self(), {:poll_subscription_oauth, attempt_id}, poll_interval_ms(device))
  end

  defp poll_interval_ms(device) do
    cond do
      is_integer(device[:interval_ms]) -> max(1, device.interval_ms)
      is_integer(device[:interval_seconds]) -> max(1, device.interval_seconds) * 1000
      true -> XaiOAuth.default_poll_interval_seconds() * 1000
    end
  end

  defp ensure_subscription_provider(%{id: provider_id, preset: preset}) do
    case ModelConfig.add_provider(provider_id, preset) do
      :ok ->
        :ok

      {:error, message} ->
        if String.contains?(message, "already exists") do
          ModelConfig.update_provider(provider_id, Map.drop(preset, ["models"]))
        else
          {:error, message}
        end
    end
  end

  # Catalog lookup takes a cluster-wide lock. Doing it while mounting stalls
  # the nested LiveView long enough for the settings page to stay blank, so
  # stored prices render immediately and missing ones fill in afterwards.
  defp schedule_catalog_prices(socket, providers) do
    ids = Projection.unpriced_model_ids(providers)
    generation = socket.assigns.catalog_price_generation + 1

    socket =
      socket
      |> cancel_catalog_async(generation - 1)
      |> assign(:catalog_price_generation, generation)

    cond do
      ids == [] or not connected?(socket) ->
        socket

      true ->
        start_async(socket, {:catalog_prices, generation}, fn ->
          Projection.lookup_catalog_prices(ids)
        end)
    end
  end

  defp cancel_catalog_async(socket, generation) when generation > 0,
    do: cancel_async(socket, {:catalog_prices, generation})

  defp cancel_catalog_async(socket, _generation), do: socket

  defp reload_providers(socket) do
    config = Projection.load_raw_config()
    providers = Projection.parse_providers(config)
    selected_id = Projection.maybe_reselect(socket.assigns.selected_provider_id, providers)

    socket
    |> assign(:config, config)
    |> assign(:providers, providers)
    |> assign(:selected_provider_id, selected_id)
    |> assign(:selected_provider, Projection.find_provider(selected_id, providers))
    |> schedule_catalog_prices(providers)
  end

  defdelegate obscured_api_key(key), to: Presentation
  defdelegate format_context(number), to: Presentation
  defdelegate format_price(cost), to: Presentation
  defdelegate delete_confirm_title(target), to: Presentation
  defdelegate delete_confirm_message(target, providers), to: Presentation
  defdelegate reasoning_level_label(level), to: Presentation
  defdelegate reasoning_levels_for(provider_id, model), to: Presentation
  defdelegate configurable_reasoning_levels(form), to: Forms

  defp reasoning_level_checked?(form, level), do: Forms.reasoning_level_checked?(form, level)
end
