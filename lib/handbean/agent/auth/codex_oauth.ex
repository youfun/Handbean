defmodule Handbean.Agent.Auth.CodexOAuth do
  @moduledoc """
  ChatGPT device authorization for the Codex backend. No Codex CLI is required.

  The device endpoints are the Codex client's two-stage flow, not the standard
  OAuth device token grant. Endpoint compatibility follows openai/codex.
  """

  @issuer "https://auth.openai.com"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @verification_uri "https://auth.openai.com/codex/device"
  @redirect_uri "https://auth.openai.com/deviceauth/callback"
  @lifetime_seconds 900

  def start(opts \\ []) do
    with {:ok, body} <-
           request("/api/accounts/deviceauth/usercode", :json, %{client_id: @client_id}, opts),
         {:ok, device_code} <- required_string(body, "device_auth_id"),
         {:ok, user_code} <- required_string(body, "user_code") do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: @verification_uri,
         interval_seconds: interval(body["interval"]),
         expires_in_seconds: @lifetime_seconds,
         expires_at: now(opts) + @lifetime_seconds * 1000
       }}
    end
  end

  def poll_once(device, opts \\ []) do
    if now(opts) >= device.expires_at do
      {:error, "ChatGPT device code expired. Start sign-in again."}
    else
      poll_device(device, opts)
    end
  end

  def refresh(refresh_token, opts \\ []) do
    with {:ok, body} <-
           request(
             "/oauth/token",
             :form,
             %{
               grant_type: "refresh_token",
               client_id: @client_id,
               refresh_token: refresh_token
             },
             opts
           ) do
      credentials(body, refresh_token, opts)
    end
  end

  def browser_verification_uri(_device), do: @verification_uri
  def default_poll_interval_seconds, do: 5

  # Only extract the account routing claim. This does not verify JWT signatures;
  # the token is issued by the TLS-authenticated OAuth endpoint.
  def account_id(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"https://api.openai.com/auth" => claims}} when is_map(claims) <-
           Handbean.JSON.decode(json),
         {:ok, id} <- required_string(claims, "chatgpt_account_id") do
      {:ok, id}
    else
      _ -> {:error, "ChatGPT credential is missing its account ID. Sign in again."}
    end
  end

  def account_id(_), do: {:error, "ChatGPT credential is missing its account ID. Sign in again."}

  defp poll_device(device, opts) do
    result =
      request(
        "/api/accounts/deviceauth/token",
        :json,
        %{
          device_auth_id: device.device_code,
          user_code: device.user_code
        },
        opts
      )

    case result do
      {:ok, body} ->
        with {:ok, code} <- required_string(body, "authorization_code"),
             {:ok, verifier} <- required_string(body, "code_verifier"),
             {:ok, tokens} <-
               request(
                 "/oauth/token",
                 :form,
                 %{
                   grant_type: "authorization_code",
                   client_id: @client_id,
                   code: code,
                   code_verifier: verifier,
                   redirect_uri: @redirect_uri
                 },
                 opts
               ),
             {:ok, credential} <- credentials(tokens, nil, opts) do
          {:authorized, credential}
        end

      {:http_error, status, error}
      when status in [403, 404] and error not in ["access_denied", "expired_token"] ->
        {:pending, device}

      {:http_error, _status, "authorization_pending"} ->
        {:pending, device}

      {:http_error, status, error} when status == 429 or error == "slow_down" ->
        {:slow_down, %{device | interval_seconds: device.interval_seconds + 5}}

      error ->
        normalize_error(error)
    end
  end

  defp credentials(body, previous_refresh, opts) do
    body = Map.put_new(body, "refresh_token", previous_refresh)

    with {:ok, access} <- required_string(body, "access_token"),
         {:ok, refresh} <- required_string(body, "refresh_token"),
         {:ok, _id} <- account_id(access),
         {:ok, seconds} <- token_lifetime(body) do
      {:ok,
       %{
         type: "oauth",
         access: access,
         refresh: refresh,
         expires: now(opts) + seconds * 1000 - min(300, div(seconds, 2)) * 1000
       }}
    end
  end

  defp token_lifetime(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0,
    do: {:ok, seconds}

  defp token_lifetime(_), do: {:error, "Invalid ChatGPT OAuth token lifetime"}

  defp request(path, encoding, fields, opts) do
    req =
      Keyword.get(opts, :req_module, Application.get_env(:handbean, :codex_oauth_req_module, Req))

    options = [
      {encoding, fields},
      {:retry, false},
      {:redirect, false},
      {:receive_timeout, 30_000},
      {:connect_options, [timeout: 10_000]}
    ]

    case req.post(@issuer <> path, options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode_body(body)

      {:ok, %{status: status, body: body}} ->
        {:http_error, status, error_code(body)}

      {:error, _reason} ->
        {:error, "ChatGPT OAuth network request failed. Try again."}
    end
    |> normalize_request_error(path)
  end

  defp normalize_request_error(result, "/api/accounts/deviceauth/token"), do: result
  defp normalize_request_error(result, _path), do: normalize_error(result)

  defp normalize_error({:http_error, status, "invalid_grant"}),
    do: {:error, "ChatGPT authorization expired or was revoked (HTTP #{status}). Sign in again."}

  defp normalize_error({:http_error, status, _}),
    do: {:error, "ChatGPT OAuth request failed (HTTP #{status})."}

  defp normalize_error(result), do: result

  defp decode_body(body) when is_map(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, "Invalid ChatGPT OAuth response"}
    end
  end

  defp decode_body(_), do: {:error, "Invalid ChatGPT OAuth response"}

  defp error_code(body) do
    case decode_body(body) do
      {:ok, %{"error" => code}} when is_binary(code) -> code
      _ -> nil
    end
  end

  defp required_string(body, key) do
    case body[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Invalid ChatGPT OAuth response field: #{key}"}
    end
  end

  defp interval(value) when is_integer(value) and value > 0, do: value

  defp interval(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> default_poll_interval_seconds()
    end
  end

  defp interval(_), do: default_poll_interval_seconds()
  defp now(opts), do: Keyword.get(opts, :now_ms, System.system_time(:millisecond))
end
