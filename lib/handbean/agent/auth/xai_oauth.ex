defmodule Handbean.Agent.Auth.XaiOAuth do
  @moduledoc """
  xAI OAuth device-code flow, ported from pi's `packages/ai/src/auth/oauth/xai.ts`.

  The public client ID, scopes, endpoints, and `referrer=pi` are the
  subscription login contract xAI already accepts for this flow.
  """

  @client_id "b1a00492-073a-47ea-816f-4c329264a828"
  @scope "openid profile email offline_access grok-cli:access api:access"
  @device_url "https://auth.x.ai/oauth2/device/code"
  @token_url "https://auth.x.ai/oauth2/token"
  @refresh_skew_ms 5 * 60 * 1000
  @default_token_lifetime_seconds 3600
  @default_poll_interval_seconds 5
  @slow_down_increment_seconds 5
  @minimum_interval_seconds 1

  @type device :: %{
          required(:device_code) => String.t(),
          required(:user_code) => String.t(),
          required(:verification_uri) => String.t(),
          required(:expires_in_seconds) => pos_integer(),
          optional(:verification_uri_complete) => String.t() | nil,
          optional(:interval_seconds) => pos_integer() | nil
        }

  @type credential :: %{
          type: String.t(),
          access: String.t(),
          refresh: String.t(),
          expires: integer()
        }

  @spec start(keyword()) :: {:ok, device()} | {:error, String.t()}
  def start(opts \\ []) do
    case post_form(
           @device_url,
           %{
             "client_id" => client_id(),
             "scope" => @scope,
             "referrer" => "pi"
           },
           opts
         ) do
      {:ok, %{ok?: true, body: body}} ->
        parse_device_code(body)

      {:ok, response} ->
        {:error, request_failure("device authorization", response)}

      {:error, message} ->
        {:error, message}
    end
  end

  @spec poll_once(device(), keyword()) ::
          {:pending, device()}
          | {:slow_down, device()}
          | {:authorized, credential()}
          | {:error, String.t()}
  def poll_once(device, opts \\ []) do
    case post_form(
           @token_url,
           %{
             "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
             "client_id" => client_id(),
             "device_code" => device.device_code
           },
           opts
         ) do
      {:ok, %{ok?: true, body: body}} ->
        with {:ok, credential} <- credentials_from_token_response(body, nil, opts) do
          {:authorized, credential}
        end

      {:ok, %{body: body} = response} ->
        case Map.get(body, "error") do
          "authorization_pending" ->
            {:pending, device}

          "slow_down" ->
            {:slow_down, apply_slow_down(device, Map.get(body, "interval"))}

          error when error in ["access_denied", "authorization_denied"] ->
            {:error, "xAI device authorization was denied"}

          "expired_token" ->
            {:error, "xAI device code expired"}

          _ ->
            {:error, request_failure("device token polling", response)}
        end

      {:error, message} ->
        {:error, message}
    end
  end

  @spec refresh(String.t(), keyword()) :: {:ok, credential()} | {:error, String.t()}
  def refresh(refresh_token, opts \\ []) when is_binary(refresh_token) do
    case post_form(
           @token_url,
           %{
             "grant_type" => "refresh_token",
             "client_id" => client_id(),
             "refresh_token" => refresh_token
           },
           opts
         ) do
      {:ok, %{ok?: true, body: body}} ->
        credentials_from_token_response(body, refresh_token, opts)

      {:ok, response} ->
        {:error, request_failure("token refresh", response)}

      {:error, message} ->
        {:error, message}
    end
  end

  @spec to_auth(map()) :: %{api_key: String.t()}
  def to_auth(%{access: access}) when is_binary(access), do: %{api_key: access}
  def to_auth(%{"access" => access}) when is_binary(access), do: %{api_key: access}

  @spec browser_verification_uri(device()) :: String.t()
  def browser_verification_uri(%{verification_uri_complete: uri})
      when is_binary(uri) and uri != "",
      do: uri

  def browser_verification_uri(%{verification_uri: uri}), do: uri

  @spec default_poll_interval_seconds() :: pos_integer()
  def default_poll_interval_seconds, do: @default_poll_interval_seconds

  defp client_id do
    case System.get_env("XAI_OAUTH_CLIENT_ID") do
      id when is_binary(id) and id != "" -> id
      _ -> @client_id
    end
  end

  defp post_form(url, fields, opts) do
    req_mod =
      Keyword.get(opts, :req_module) ||
        Process.get(:xai_oauth_req_module) ||
        Application.get_env(:handbean, :xai_oauth_req_module) ||
        Req

    headers = [
      {"accept", "application/json"},
      {"content-type", "application/x-www-form-urlencoded"}
    ]

    case req_mod.post(url, form: fields, headers: headers) do
      {:ok, %{status: status, body: body}} ->
        {:ok, %{ok?: status >= 200 and status < 300, status: status, body: normalize_body(body)}}

      {:error, reason} ->
        {:error, "xAI OAuth request failed: #{inspect(reason)}"}
    end
  end

  defp normalize_body(body) when is_map(body), do: stringify_keys(body)

  defp normalize_body(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp normalize_body(_), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp parse_device_code(body) do
    with {:ok, device_code} <- required_string(body, "device_code"),
         {:ok, user_code} <- required_string(body, "user_code"),
         {:ok, verification_uri} <- required_string(body, "verification_uri"),
         {:ok, verification_uri} <- validate_verification_uri(verification_uri),
         {:ok, expires_in} <- positive_number(body, "expires_in"),
         {:ok, verification_uri_complete} <- optional_verification_uri_complete(body) do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: verification_uri,
         verification_uri_complete: verification_uri_complete,
         interval_seconds: optional_positive_interval(body),
         expires_in_seconds: expires_in
       }}
    end
  end

  defp optional_verification_uri_complete(body) do
    case Map.get(body, "verification_uri_complete") do
      uri when is_binary(uri) and uri != "" ->
        validate_verification_uri(uri)

      _ ->
        {:ok, nil}
    end
  end

  defp optional_positive_interval(body) do
    case Map.get(body, "interval") do
      interval when is_number(interval) and interval > 0 -> trunc(interval)
      _ -> nil
    end
  end

  defp apply_slow_down(device, interval) when is_number(interval) and interval > 0 do
    Map.put(device, :interval_seconds, max(@minimum_interval_seconds, trunc(interval)))
  end

  defp apply_slow_down(device, _interval) do
    current = device[:interval_seconds] || @default_poll_interval_seconds
    Map.put(device, :interval_seconds, current + @slow_down_increment_seconds)
  end

  defp credentials_from_token_response(body, previous_refresh_token, opts) do
    with {:ok, access} <- required_string(body, "access_token"),
         {:ok, refresh} <- refresh_token_from_response(body, previous_refresh_token),
         {:ok, expires_in} <- expires_in_from_response(body) do
      now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

      {:ok,
       %{
         type: "oauth",
         access: access,
         refresh: refresh,
         expires: now_ms + expires_in * 1000 - @refresh_skew_ms
       }}
    end
  end

  defp refresh_token_from_response(body, previous_refresh_token) do
    case Map.get(body, "refresh_token") do
      nil when is_binary(previous_refresh_token) ->
        {:ok, previous_refresh_token}

      _ ->
        required_string(body, "refresh_token")
    end
  end

  defp expires_in_from_response(body) do
    case Map.get(body, "expires_in") do
      nil -> {:ok, @default_token_lifetime_seconds}
      _ -> positive_number(body, "expires_in")
    end
  end

  defp required_string(body, field) do
    case Map.get(body, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, "Invalid xAI OAuth response field: #{field}"}
    end
  end

  defp positive_number(body, field) do
    case Map.get(body, field) do
      value when is_number(value) and value > 0 ->
        {:ok, trunc(value)}

      _ ->
        {:error, "Invalid xAI OAuth response field: #{field}"}
    end
  end

  defp validate_verification_uri(raw) do
    uri = URI.parse(raw)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      {:ok, URI.to_string(uri)}
    else
      {:error, "Untrusted verification URI in xAI OAuth response"}
    end
  end

  defp request_failure(action, %{status: status, body: body}) do
    error = string_or_nil(Map.get(body, "error"))
    description = string_or_nil(Map.get(body, "error_description"))
    detail = Enum.reject([error, description], &is_nil/1) |> Enum.join(": ")

    if detail == "" do
      "xAI OAuth #{action} failed (HTTP #{status})"
    else
      "xAI OAuth #{action} failed (HTTP #{status}): #{detail}"
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
end
