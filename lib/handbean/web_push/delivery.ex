defmodule Handbean.WebPush.Delivery do
  @moduledoc "Encrypted Web Push transport. HTTP work never runs in the task lifecycle owner."

  use Gettext, backend: Handbean.Gettext

  alias Handbean.WebPush
  alias Handbean.WebPush.Endpoint
  alias Handbean.WebPush.Keys
  alias Handbean.WebPush.Protocol

  @doc "Fan out one notification with bounded concurrency; return only transient failures for retry."
  def deliver(event, subscriptions \\ nil) do
    if relevant?(event) do
      case subscriptions || WebPush.subscriptions() do
        [] ->
          %{subscriptions: [], retry_after: 0}

        subscriptions ->
          deliver_subscriptions(event, subscriptions)
      end
    else
      %{subscriptions: [], retry_after: 0}
    end
  end

  defp deliver_subscriptions(event, subscriptions) do
    with {:ok, keys} <- ensure_vapid_keys(),
         {:ok, encoded_payloads} <- encode_payloads(event, subscriptions) do
      subject = WebPush.subject()

      results =
        Task.async_stream(
          subscriptions,
          fn subscription ->
            result =
              if relevant?(event) do
                send_encoded_notification(
                  subscription,
                  Map.fetch!(encoded_payloads, subscription.locale),
                  keys,
                  subject
                )
              else
                :ok
              end

            {subscription, result}
          end,
          max_concurrency: 4,
          timeout: 15_000,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.zip(subscriptions)

      Enum.reduce(results, %{subscriptions: [], retry_after: 0}, fn
        {{:ok, {subscription, {:error, {:transient, delay}}}}, _}, retry ->
          %{
            subscriptions: [subscription | retry.subscriptions],
            retry_after: max(delay, retry.retry_after)
          }

        {{:exit, _}, subscription}, retry ->
          %{
            subscriptions: [subscription | retry.subscriptions],
            retry_after: max(1_000, retry.retry_after)
          }

        _, retry ->
          retry
      end)
    else
      {:error, _reason} ->
        %{subscriptions: subscriptions, retry_after: 1_000}
    end
  end

  defp ensure_vapid_keys do
    Keys.ensure()
  rescue
    error -> {:error, error}
  end

  @doc "Send a test through the same encrypted provider path as task notifications."
  def test(subscription) do
    payload =
      Gettext.with_locale(Handbean.Gettext, subscription.locale, fn ->
        %{
          title: "Handbean",
          body: gettext("Background notifications are ready on this device."),
          url: "/settings?tab=ui",
          tag: "handbean-push-test"
        }
      end)

    send_notification(subscription, payload)
  end

  @doc "Notification content never includes the conversation title, prompt, or model response."
  def payload(event, locale) do
    task = event_task(event)

    Gettext.with_locale(Handbean.Gettext, locale, fn ->
      %{
        title: "Handbean",
        body: message(event),
        url: conversation_path(task),
        tag: "handbean-" <> Base.url_encode64(:crypto.hash(:sha256, task.run_id), padding: false)
      }
    end)
  end

  defp encode_payloads(event, subscriptions) do
    subscriptions
    |> Enum.map(& &1.locale)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn locale, {:ok, acc} ->
      case Handbean.JSON.encode(payload(event, locale)) do
        {:ok, encoded} -> {:cont, {:ok, Map.put(acc, locale, encoded)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp send_notification(subscription, payload) do
    with {:ok, keys} <- Keys.ensure(),
         {:ok, encoded} <- Handbean.JSON.encode(payload) do
      send_encoded_notification(subscription, encoded, keys, WebPush.subject())
    end
  end

  defp send_encoded_notification(subscription, encoded, keys, subject) do
    if WebPush.current?(subscription) do
      with :ok <- Endpoint.validate(subscription.endpoint),
           {:ok, authorization} <-
             Protocol.authorization(subscription.endpoint, keys, subject),
           {:ok, body} <-
             Protocol.encrypt(encoded, %{
               "p256dh" => subscription.p256dh,
               "auth" => subscription.auth
             }) do
        result = request(subscription.endpoint, authorization, body)
        if result == {:error, :expired}, do: WebPush.expire(subscription)
        result
      end
    else
      {:error, :not_found}
    end
  end

  defp request(endpoint, authorization, body) do
    options =
      Application.get_env(:handbean, :web_push, [])
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        url: endpoint,
        method: :post,
        headers: [
          {"authorization", authorization},
          {"content-encoding", "aes128gcm"},
          {"content-type", "application/octet-stream"},
          {"ttl", "3600"},
          {"urgency", "normal"}
        ],
        body: body,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 5_000]
      )

    case Req.request(options) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} when status in [404, 410] ->
        {:error, :expired}

      {:ok, %{status: status} = response} when status in [408, 425, 429] or status in 500..599 ->
        {:error, {:transient, retry_after(response)}}

      {:ok, _response} ->
        {:error, :delivery_failed}

      {:error, _reason} ->
        {:error, {:transient, 1_000}}
    end
  end

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> min(max(seconds * 1_000, 1_000), 300_000)
          _ -> 1_000
        end

      _ ->
        1_000
    end
  end

  defp relevant?({:waiting, task}) do
    Enum.any?(Handbean.Runtime.TaskTracker.snapshot().tasks, fn current ->
      current.conversation_id == task.conversation_id and current.run_id == task.run_id and
        current.status == :waiting_confirmation and
        current.waiting_episode == task.waiting_episode
    end)
  end

  defp relevant?({:ended, _task, reason}), do: reason in [:completed, :failed]

  defp event_task({:waiting, task}), do: task
  defp event_task({:ended, task, _}), do: task
  defp message({:waiting, _}), do: gettext("A task needs your confirmation.")
  defp message({:ended, _, :completed}), do: gettext("A task has completed.")
  defp message({:ended, _, :failed}), do: gettext("A task stopped with an error.")

  defp conversation_path(%{workspace_id: workspace_id, conversation_id: conversation_id})
       when is_binary(workspace_id) and workspace_id != "" do
    "/w/#{URI.encode_www_form(workspace_id)}/c/#{URI.encode_www_form(conversation_id)}"
  end

  defp conversation_path(%{conversation_id: conversation_id}),
    do: "/c/#{URI.encode_www_form(conversation_id)}"
end
