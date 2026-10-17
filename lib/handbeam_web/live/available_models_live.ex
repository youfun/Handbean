defmodule HandbeamWeb.AvailableModelsLive do
  use HandbeamWeb, :live_view

  alias Handbeam.Agent.Auth.{
    CodexCredential,
    CodexOAuth,
    CursorCredential,
    CursorOAuth,
    Epoch,
    Storage,
    Subscriptions,
    XaiOAuth
  }

  alias Handbeam.Agent.Provider.Codex.Models, as: CodexModels
  alias Handbeam.Agent.Provider.Cursor.Models, as: CursorModels
  alias Handbeam.Agent.Provider.ModelCatalog
  alias Handbeam.Agent.ModelConfig
  alias Handbeam.Agent.Reasoning
  alias Handbeam.LlmDbDefaults

  # ── Lifecycle ──────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Handbeam.PubSub, "models:updated")

    ModelConfig.ensure_config()
    config = load_raw_config()
    providers = parse_providers(config)
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
      |> assign(:selected_provider, find_provider(selected_id, providers))
      |> assign(:show_add_provider, false)
      |> assign(:show_edit_provider, false)
      |> assign(:show_add_model, false)
      |> assign(:show_delete_confirm, false)
      |> assign(:delete_target, nil)
      |> assign(:add_provider_form, reset_add_provider_form())
      |> assign(:edit_provider_form, %{})
      |> assign(:add_model_form, reset_add_model_form())
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
    config = load_raw_config()
    providers = parse_providers(config)
    selected_id = maybe_reselect(socket.assigns.selected_provider_id, providers)

    socket =
      socket
      |> assign(:config, config)
      |> assign(:providers, providers)
      |> assign(:selected_provider_id, selected_id)
      |> assign(:selected_provider, find_provider(selected_id, providers))
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
      providers = apply_catalog_prices(socket.assigns.providers, prices)

      {:noreply,
       socket
       |> assign(:providers, providers)
       |> assign(
         :selected_provider,
         find_provider(socket.assigns.selected_provider_id, providers)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:catalog_prices, _generation}, {:exit, _reason}, socket),
    do: {:noreply, socket}

  # ── Subscription OAuth ─────────────────────────────────────────────────

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
    enabled = not model_enabled?(socket, provider_id, model_id)

    case ModelConfig.update_model(provider_id, model_id, %{"enabled" => enabled}) do
      :ok ->
        {:noreply, reload_providers(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, reason)}
    end
  end

  # ── Provider selection ─────────────────────────────────────────────────

  @impl true
  def handle_event("select_provider", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider_id, id)
     |> assign(:selected_provider, find_provider(id, socket.assigns.providers))}
  end

  def handle_event("clear_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider_id, nil)
     |> assign(:selected_provider, nil)}
  end

  # ── Default provider toggle ────────────────────────────────────────────

  @impl true
  def handle_event("toggle_default_provider", %{"id" => id, "value" => value}, socket) do
    if value == "true" do
      case ModelConfig.set_default_provider(id) do
        :ok ->
          toast = %{
            type: :success,
            message: gettext("默认供应商已更改"),
            id: System.unique_integer([:positive])
          }

          Process.send_after(self(), :clear_toast, 3000)
          {:noreply, assign(socket, :toast, toast)}

        {:error, reason} ->
          {:noreply, assign(socket, :form_error, reason)}
      end
    else
      # Cannot uncheck default — at least for now, require one default
      {:noreply, socket}
    end
  end

  # ── Add provider ───────────────────────────────────────────────────────

  @impl true
  def handle_event("open_add_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_provider, true)
     |> assign(:form_error, nil)
     |> assign(:add_provider_form, reset_add_provider_form())}
  end

  def handle_event("close_add_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_provider, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("update_add_provider", %{"add_provider" => params}, socket) do
    previous = socket.assigns.add_provider_form
    form = previous |> Map.merge(params) |> maybe_apply_subscription_preset()
    {:noreply, assign(socket, :add_provider_form, form)}
  end

  def handle_event("update_add_provider", _params, socket) do
    # Form change with partial params (e.g., only _target)
    {:noreply, socket}
  end

  def handle_event("submit_add_provider", %{"add_provider" => params}, socket) do
    params =
      socket.assigns.add_provider_form
      |> Map.merge(params)
      |> maybe_apply_subscription_preset()
      |> hydrate_add_provider_form(true)

    name = params["name"] |> to_string() |> String.trim()
    api = params["api"] |> to_string() |> String.trim()
    base_url = params["base_url"] |> to_string() |> String.trim()
    api_key = params["api_key"] |> to_string() |> String.trim()

    provider_id =
      params["id"]
      |> to_string()
      |> String.trim()
      |> present_or(generated_provider_id(name, socket.assigns.providers))

    cond do
      provider_id == "" ->
        {:noreply, assign(socket, :form_error, gettext("Provider ID 不能为空"))}

      not String.match?(provider_id, ~r/^[a-z0-9_-]+$/) ->
        {:noreply, assign(socket, :form_error, gettext("Provider ID 只能包含小写字母、数字、横线和下划线"))}

      true ->
        provider_attrs = %{
          "provider" => runtime_provider(params, provider_id),
          "baseUrl" => base_url,
          "api" => api,
          "apiKey" => api_key,
          "name" => present_or(name, display_name(provider_id)),
          "models" => subscription_seed_models(provider_id)
        }

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
             |> assign(:add_provider_form, reset_add_provider_form())
             |> assign(:toast, toast)}

          {:error, reason} ->
            {:noreply, assign(socket, :form_error, reason)}
        end
    end
  end

  def handle_event("submit_add_provider", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  # ── Edit provider ──────────────────────────────────────────────────────

  @impl true
  def handle_event("open_edit_provider", %{"id" => id}, socket) do
    provider = find_provider(id, socket.assigns.providers)

    {:noreply,
     socket
     |> assign(:show_edit_provider, true)
     |> assign(:form_error, nil)
     |> assign(:edit_provider_form, %{
       "name" => provider.name,
       "api" => provider.api,
       "base_url" => provider.base_url,
       "api_key" => form_api_key(provider.api_key)
     })}
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
    params = Map.merge(socket.assigns.edit_provider_form, params)

    attrs =
      %{
        "name" => params["name"],
        "api" => params["api"],
        "baseUrl" => params["base_url"]
      }
      |> maybe_put_api_key(params["api_key"])

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
         |> assign(:toast, toast)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, reason)}
    end
  end

  def handle_event("submit_edit_provider", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  # ── Delete provider / model ────────────────────────────────────────────

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

  # ── Add model ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_add_model", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_model, true)
     |> assign(:form_error, nil)
     |> assign(:add_model_form, reset_add_model_form())}
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
    params = socket.assigns.add_model_form |> Map.merge(params) |> hydrate_add_model_form(true)

    model_id = params["id"] |> to_string() |> String.trim()
    model_name = params["name"] |> to_string() |> String.trim()
    type = params["type"] |> to_string() |> String.trim()

    if model_id == "" do
      {:noreply, assign(socket, :form_error, gettext("模型 ID 不能为空"))}
    else
      model_cost = build_cost_map(params)

      model_attrs =
        %{
          "name" => present_or(model_name, model_id),
          "input" => [type || "text"],
          "contextWindow" => parse_int(params["context_window"], 128_000),
          "maxTokens" => parse_int(params["max_tokens"], 8192),
          "cost" => model_cost
        }
        |> maybe_put_reasoning(Map.put(params, "provider_id", provider_id), model_id)
        |> maybe_drop_empty_cost()

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
           |> assign(:add_model_form, reset_add_model_form())
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

  # ── Clear error ───────────────────────────────────────────────────────

  @impl true
  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, :form_error, nil)}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  def obscured_api_key(key) when is_binary(key) do
    cond do
      key == "" -> "—"
      String.starts_with?(key, "env:") -> "••••••••"
      String.length(key) > 12 -> String.slice(key, 0, 6) <> "..." <> String.slice(key, -4, 4)
      true -> String.slice(key, 0, 4) <> "..."
    end
  end

  def obscured_api_key(nil), do: "—"

  defp form_api_key("env:" <> _var), do: ""
  defp form_api_key(key) when is_binary(key), do: key
  defp form_api_key(_), do: ""

  defp maybe_put_api_key(attrs, api_key) do
    case api_key |> to_string() |> String.trim() do
      "" -> attrs
      key -> Map.put(attrs, "apiKey", key)
    end
  end

  def format_context(nil), do: "—"
  def format_context(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  def format_context(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  def format_context(n) when is_integer(n), do: Integer.to_string(n)

  def format_price(%{"input" => input, "output" => output})
      when is_number(input) and is_number(output) do
    "in #{format_price_number(input)} / out #{format_price_number(output)}"
  end

  def format_price(%{input: input, output: output}) when is_number(input) and is_number(output) do
    "in #{format_price_number(input)} / out #{format_price_number(output)}"
  end

  def format_price(_), do: "—"

  def delete_confirm_title(%{type: :provider}), do: gettext("删除供应商")
  def delete_confirm_title(%{type: :model}), do: gettext("删除模型")
  def delete_confirm_title(_), do: gettext("确认删除")

  def delete_confirm_message(%{type: :provider, id: id}, providers) do
    name =
      case Enum.find(providers, &(&1.id == id)) do
        nil -> id
        p -> p.name
      end

    gettext("确认删除供应商「%{name}」(ID: %{id})？这将同时删除其下所有模型。", name: name, id: id)
  end

  def delete_confirm_message(%{type: :model, model_id: mid}, _providers) do
    gettext("确认删除模型「%{id}」？", id: mid)
  end

  def delete_confirm_message(_, _), do: gettext("确认删除？")

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
        find_provider(method.id, parse_providers(load_raw_config()))
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

    socket
    |> cancel_discovery_async(:provider)
    |> start_async({:provider_models, attempt_id}, fn -> ModelCatalog.discover(provider_id) end)
    |> assign(:catalog_discover_attempt, attempt_id)
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
          models = preserve_model_enabled(models, "cursor")

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
          models = CodexModels.preserve_enabled(models, stored_models("openai_codex"))

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
    ids = unpriced_model_ids(providers)
    generation = socket.assigns.catalog_price_generation + 1

    socket =
      socket
      |> cancel_catalog_async(generation - 1)
      |> assign(:catalog_price_generation, generation)

    cond do
      ids == [] or not connected?(socket) ->
        socket

      true ->
        start_async(socket, {:catalog_prices, generation}, fn -> lookup_catalog_prices(ids) end)
    end
  end

  defp cancel_catalog_async(socket, generation) when generation > 0,
    do: cancel_async(socket, {:catalog_prices, generation})

  defp cancel_catalog_async(socket, _generation), do: socket

  defp lookup_catalog_prices(ids), do: LlmDbDefaults.prices_for_model_ids(ids)

  defp unpriced_model_ids(providers) do
    providers
    |> Enum.flat_map(& &1.models)
    |> Enum.filter(&(map_size(&1.cost) == 0))
    |> Enum.map(& &1.id)
    |> Enum.filter(&is_binary/1)
  end

  defp apply_catalog_prices(providers, prices) do
    Enum.map(providers, fn provider ->
      models =
        Enum.map(provider.models, fn model ->
          case Map.get(prices, model.id) do
            %{} = cost when map_size(cost) > 0 and map_size(model.cost) == 0 ->
              %{model | cost: cost}

            _ ->
              model
          end
        end)

      %{provider | models: models}
    end)
  end

  defp model_enabled?(socket, provider_id, model_id) do
    provider = find_provider(provider_id, socket.assigns.providers)
    model = provider && Enum.find(provider.models, &(&1.id == model_id))
    (model && model.enabled) || false
  end

  defp display_cost(%{"cost" => cost}) when is_map(cost) and map_size(cost) > 0, do: cost
  defp display_cost(_), do: %{}

  defp stored_models(provider_id) do
    case load_raw_config() do
      %{"providers" => %{^provider_id => %{"models" => models}}} when is_list(models) -> models
      _ -> []
    end
  end

  defp preserve_model_enabled(models, provider_id) do
    previous =
      case load_raw_config() do
        %{"providers" => %{^provider_id => %{"models" => existing}}} when is_list(existing) ->
          Map.new(existing, fn model -> {model["id"], model["enabled"]} end)

        _ ->
          %{}
      end

    Enum.map(models, fn model ->
      case Map.get(previous, model["id"]) do
        enabled when is_boolean(enabled) -> Map.put(model, "enabled", enabled)
        _ -> model
      end
    end)
  end

  defp reload_providers(socket) do
    config = load_raw_config()
    providers = parse_providers(config)
    selected_id = maybe_reselect(socket.assigns.selected_provider_id, providers)

    socket
    |> assign(:config, config)
    |> assign(:providers, providers)
    |> assign(:selected_provider_id, selected_id)
    |> assign(:selected_provider, find_provider(selected_id, providers))
    |> schedule_catalog_prices(providers)
  end

  defp load_raw_config do
    path = ModelConfig.config_file_path()

    case File.read(path) do
      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, json} when is_map(json) -> json
          _ -> empty_config()
        end

      _ ->
        empty_config()
    end
  end

  defp empty_config, do: %{"defaultProvider" => "", "providers" => %{}}

  defp parse_providers(config) do
    providers = Map.get(config, "providers", %{})
    default = Map.get(config, "defaultProvider", "")

    Enum.map(providers, fn {id, pc} ->
      %{
        id: id,
        name: Map.get(pc, "name", display_name(id)),
        api: Map.get(pc, "api", ""),
        base_url: Map.get(pc, "baseUrl", ""),
        api_key: Map.get(pc, "apiKey", ""),
        auth_type: Map.get(pc, "authType", "api_key"),
        fetchable: ModelCatalog.fetchable?(pc),
        is_default: id == default,
        provider: Map.get(pc, "provider", id),
        models:
          Map.get(pc, "models", [])
          |> Enum.map(fn m ->
            %{
              id: Map.get(m, "id", ""),
              name: Map.get(m, "name", ""),
              type: List.first(Map.get(m, "input", ["text"])) || "text",
              reasoning: Map.get(m, "reasoning") == true,
              thinking_level_map: Map.get(m, "thinkingLevelMap", %{}),
              context_window: Map.get(m, "contextWindow"),
              max_tokens: Map.get(m, "maxTokens"),
              cost: display_cost(m),
              enabled: Map.get(m, "enabled") != false
            }
          end)
      }
    end)
  end

  defp display_name(id) do
    id |> String.capitalize()
  end

  defp find_provider(id, providers) do
    Enum.find(providers, &(&1.id == id))
  end

  defp maybe_reselect(current_id, providers) do
    if current_id && Enum.any?(providers, &(&1.id == current_id)) do
      current_id
    else
      providers |> List.first() |> then(&if(&1, do: &1.id))
    end
  end

  @subscription_presets ["ollama", "ollama-cloud", "ollama_cloud", "opencode-go", "opencode_go"]

  defp maybe_apply_subscription_preset(form) do
    case Handbeam.Agent.Provider.SubscriptionCatalog.preset(form["id"]) do
      nil ->
        form

      preset ->
        form
        |> Map.put("id", preset["provider"])
        |> Map.put("name", preset["name"])
        |> Map.put("base_url", preset["baseUrl"])
        |> Map.put("api", preset["api"])
        |> Map.put("provider_runtime", preset["provider"])
        |> Map.put("subscription_preset", true)
    end
  end

  defp subscription_seed_models(provider_id) do
    case Handbeam.Agent.Provider.SubscriptionCatalog.preset(provider_id) do
      %{"models" => models} when provider_id in @subscription_presets and is_list(models) ->
        models

      _ ->
        []
    end
  end

  defp reset_add_provider_form do
    %{
      "name" => "",
      "id" => "",
      "api" => "openai",
      "base_url" => "",
      "api_key" => "",
      "provider_runtime" => "",
      "model_id" => "",
      "model_name" => "",
      "context_window" => "128000",
      "max_tokens" => "8192",
      "price_input" => "",
      "price_output" => "",
      "price_cache_read" => "",
      "price_cache_write" => "",
      "price_reasoning" => "",
      "reasoning" => "false",
      "reasoning_levels" => []
    }
  end

  defp reset_add_model_form do
    %{
      "id" => "",
      "name" => "",
      "type" => "text",
      "context_window" => "128000",
      "max_tokens" => "8192",
      "price_input" => "",
      "price_output" => "",
      "price_cache_read" => "",
      "price_cache_write" => "",
      "price_reasoning" => "",
      "reasoning" => "false",
      "reasoning_levels" => []
    }
  end

  defp hydrate_add_provider_form(%{"subscription_preset" => true} = form, _force?), do: form

  defp hydrate_add_provider_form(form, force?) do
    defaults = LlmDbDefaults.defaults_for(form["id"], form["name"], form["base_url"], nil)

    form
    |> put_default("id", defaults.provider_id, false)
    |> put_default("name", defaults.provider[:provider_name], force?)
    |> put_default("base_url", defaults.provider[:base_url], force?)
    |> put_default("api", defaults.provider[:api], force?)
    |> put_default("provider_runtime", defaults.provider[:provider_runtime], force?)
  end

  defp hydrate_add_model_form(form, force?) do
    defaults = LlmDbDefaults.model_form_defaults(form["id"])

    form
    |> put_default("name", defaults[:model_name], force?)
    |> put_default("context_window", to_string_or_nil(defaults[:context_window]), force?)
    |> put_default("max_tokens", to_string_or_nil(defaults[:max_tokens]), force?)
    |> put_default("price_input", to_string_or_nil(defaults[:price_input]), force?)
    |> put_default("price_output", to_string_or_nil(defaults[:price_output]), force?)
    |> put_default("price_cache_read", to_string_or_nil(defaults[:price_cache_read]), force?)
    |> put_default("price_cache_write", to_string_or_nil(defaults[:price_cache_write]), force?)
    |> put_default("price_reasoning", to_string_or_nil(defaults[:price_reasoning]), force?)
  end

  defp generated_provider_id(name, providers) do
    existing = Enum.map(providers, & &1.id)

    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "provider"
        slug -> slug
      end

    if base in existing do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{base}-#{n}"
        unless candidate in existing, do: candidate
      end)
    else
      base
    end
  end

  defp runtime_provider(params, provider_id) do
    params
    |> Map.get("provider_runtime")
    |> present_or(provider_id)
  end

  defp build_cost_map(params) do
    %{}
    |> maybe_put_cost("input", params["price_input"])
    |> maybe_put_cost("output", params["price_output"])
    |> maybe_put_cost("cache_read", params["price_cache_read"])
    |> maybe_put_cost("cache_write", params["price_cache_write"])
    |> maybe_put_cost("reasoning", params["price_reasoning"])
  end

  defp maybe_put_cost(costs, _key, nil), do: costs

  defp maybe_put_cost(costs, key, value) do
    case parse_float(value) do
      nil -> costs
      number -> Map.put(costs, key, number)
    end
  end

  defp maybe_drop_empty_cost(%{"cost" => cost} = model) when map_size(cost) == 0,
    do: Map.delete(model, "cost")

  defp maybe_drop_empty_cost(model), do: model

  defp maybe_put_reasoning(model, params, model_id) do
    if truthy?(params["reasoning"]) do
      Map.merge(model, reasoning_catalog_fields(params, model_id))
    else
      model
    end
  end

  defp reasoning_catalog_fields(params, model_id) do
    Reasoning.catalog_fields(
      %{id: model_id, provider_id: params["provider_id"] || params["id"]},
      selected_reasoning_levels(params)
    )
  end

  defp selected_reasoning_levels(params) do
    params
    |> Map.get("reasoning_levels", [])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp reasoning_level_checked?(form, level) do
    selected = selected_reasoning_levels(form)
    selected == [] or level in selected
  end

  defp truthy?(value) when value in [true, "true", "on", "1"], do: true
  defp truthy?(_value), do: false

  def reasoning_level_label(level) do
    case level do
      "off" -> gettext("Off")
      "minimal" -> gettext("Minimal")
      "low" -> gettext("Low")
      "medium" -> gettext("Medium")
      "high" -> gettext("High")
      "xhigh" -> gettext("X-High")
      _ -> level
    end
  end

  def reasoning_levels_for(provider_id, model) do
    model
    |> Map.put(:id, model.id)
    |> Map.put(:provider_id, provider_id)
    |> Map.put(:reasoning, true)
    |> Map.put(:thinking_level_map, Map.get(model, :thinking_level_map, %{}))
    |> Reasoning.supported_levels()
  end

  def configurable_reasoning_levels(form) do
    model_id = form["model_id"] || form["id"]
    provider_id = form["provider_id"] || form["id"]

    Reasoning.configurable_levels(%{id: model_id, provider_id: provider_id, reasoning: true})
  end

  defp put_default(form, _key, nil, _force?), do: form

  defp put_default(form, key, value, true), do: Map.put(form, key, value)

  defp put_default(form, key, value, false) do
    case Map.get(form, key) do
      nil -> Map.put(form, key, value)
      "" -> Map.put(form, key, value)
      _existing -> form
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)

  defp present_or(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp present_or(nil, fallback), do: fallback
  defp present_or(value, _fallback), do: value

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(int, _default) when is_integer(int), do: int

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_float(value) when is_integer(value), do: :erlang.float(value)
  defp parse_float(value) when is_float(value), do: value

  defp format_price_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_price_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
