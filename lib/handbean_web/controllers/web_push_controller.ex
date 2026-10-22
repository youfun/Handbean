defmodule HandbeanWeb.WebPushController do
  use HandbeanWeb, :controller

  alias Handbean.WebPush
  alias Handbean.WebPush.Delivery

  @client_key "handbean_push_client"

  plug :no_store

  def config(conn, _params) do
    client_id = get_session(conn, @client_key) || Ecto.UUID.generate()
    conn = put_session(conn, @client_key, client_id)

    case WebPush.public_config() do
      {:ok, config} ->
        json(conn, Map.put(config, :locale, Gettext.get_locale(Handbean.Gettext)))

      {:error, _reason} ->
        error(conn, 503, :unavailable)
    end
  end

  def create(conn, %{"subscription" => subscription} = params) do
    with {:ok, client_id} <- client_id(conn),
         {:ok, _subscription} <-
           WebPush.subscribe(
             client_id,
             subscription,
             params["locale"] || Gettext.get_locale(Handbean.Gettext)
           ) do
      json(conn, %{ok: true})
    else
      {:error, :subscription_conflict} -> error(conn, 409, :subscription_conflict)
      {:error, :subscription_limit} -> error(conn, 429, :subscription_limit)
      {:error, :not_configured} -> error(conn, 503, :not_configured)
      {:error, :missing_client} -> error(conn, 409, :missing_client)
      {:error, _reason} -> error(conn, 422, :invalid_subscription)
    end
  end

  def create(conn, _params), do: error(conn, 422, :invalid_subscription)

  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    with {:ok, client_id} <- client_id(conn) do
      :ok = WebPush.unsubscribe(client_id, endpoint)
      json(conn, %{ok: true})
    else
      {:error, reason} -> error(conn, 409, reason)
    end
  end

  def delete(conn, _params), do: error(conn, 422, :invalid_subscription)

  def test(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    with {:ok, client_id} <- client_id(conn),
         {:ok, subscription} <- WebPush.fetch(client_id, endpoint),
         :ok <- Delivery.test(subscription) do
      json(conn, %{ok: true})
    else
      {:error, reason} when reason in [:not_found, :expired] ->
        error(conn, 410, :subscription_expired)

      {:error, :missing_client} ->
        error(conn, 409, :missing_client)

      {:error, _reason} ->
        error(conn, 503, :delivery_failed)
    end
  end

  def test(conn, _params), do: error(conn, 422, :invalid_subscription)

  def service_worker(conn, _params) do
    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("service-worker-allowed", "/")
    |> send_file(200, Path.join(Handbean.Paths.priv_dir(), "web_push/sw.js"))
  end

  defp client_id(conn) do
    case get_session(conn, @client_key) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, :missing_client}
    end
  end

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")
  defp error(conn, status, reason), do: conn |> put_status(status) |> json(%{error: reason})
end
