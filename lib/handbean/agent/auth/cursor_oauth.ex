defmodule Handbean.Agent.Auth.CursorOAuth do
  @moduledoc """
  Cursor account PKCE login against `api2.cursor.sh`.

  This is a non-official interoperability client. The login URL, poll
  endpoint, and refresh exchange follow the public browser/CLI contract
  documented by community adapters such as ephraimduncan/opencode-cursor.
  Handbean does not use the Cursor CLI, desktop app, Node, or official SDK.
  """

  @login_url "https://cursor.com/loginDeepControl"
  @poll_url "https://api2.cursor.sh/auth/poll"
  @refresh_url "https://api2.cursor.sh/auth/exchange_user_api_key"
  @refresh_skew_ms 5 * 60 * 1000
  @default_token_lifetime_seconds 3600
  @default_poll_interval_ms 1_000
  @max_poll_interval_ms 10_000
  @poll_backoff 1.2
  @max_poll_attempts 150
  @max_consecutive_errors 3

  @type device :: %{
          required(:kind) => :browser,
          required(:uuid) => String.t(),
          required(:verifier) => String.t(),
          required(:challenge) => String.t(),
          required(:verification_uri) => String.t(),
          required(:interval_ms) => pos_integer(),
          required(:attempts) => non_neg_integer(),
          required(:consecutive_errors) => non_neg_integer()
        }

  @type credential :: %{
          type: String.t(),
          access: String.t(),
          refresh: String.t(),
          expires: integer()
        }

  @spec start(keyword()) :: {:ok, device()} | {:error, String.t()}
  def start(opts \\ []) do
    verifier = Keyword.get_lazy(opts, :verifier, &generate_verifier/0)
    uuid = Keyword.get_lazy(opts, :uuid, &generate_uuid/0)
    challenge = challenge_from_verifier(verifier)

    uri =
      @login_url
      |> URI.parse()
      |> Map.put(
        :query,
        URI.encode_query(%{
          "challenge" => challenge,
          "uuid" => uuid,
          "mode" => "login",
          "redirectTarget" => "cli"
        })
      )
      |> URI.to_string()

    {:ok,
     %{
       kind: :browser,
       uuid: uuid,
       verifier: verifier,
       challenge: challenge,
       verification_uri: uri,
       interval_ms: @default_poll_interval_ms,
       attempts: 0,
       consecutive_errors: 0
     }}
  end

  @spec poll_once(device(), keyword()) ::
          {:pending, device()} | {:authorized, credential()} | {:error, String.t()}
  def poll_once(device, opts \\ []) do
    attempts = device.attempts + 1

    cond do
      attempts > max_attempts(opts) ->
        {:error, "Cursor authorization timed out. Open the login link again."}

      true ->
        do_poll(device, attempts, opts)
    end
  end

  @spec refresh(String.t(), keyword()) :: {:ok, credential()} | {:error, term()}
  def refresh(refresh_token, opts \\ []) when is_binary(refresh_token) do
    headers = [
      {"authorization", "Bearer #{refresh_token}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case http_post(@refresh_url, "{}", headers, opts) do
      {:ok, %{ok?: true, body: body}} ->
        case credentials_from_token_response(body, refresh_token, opts) do
          {:authorized, credential} -> {:ok, credential}
          other -> other
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:invalid, "Cursor subscription expired. Sign in with Cursor to reconnect."}}

      {:ok, response} ->
        {:error, {:temporary, request_failure("token refresh", response)}}

      {:error, message} ->
        {:error, {:temporary, message}}
    end
  end

  @spec to_auth(map()) :: %{api_key: String.t()}
  def to_auth(%{access: access}) when is_binary(access), do: %{api_key: access}
  def to_auth(%{"access" => access}) when is_binary(access), do: %{api_key: access}

  @spec to_auth(map(), keyword()) :: %{api_key: String.t(), auth_generation: integer()}
  def to_auth(credential, opts) when is_list(opts) do
    credential
    |> to_auth()
    |> Map.merge(Map.new(Keyword.take(opts, [:auth_generation])))
  end

  @spec browser_verification_uri(device()) :: String.t()
  def browser_verification_uri(%{verification_uri: uri}), do: uri

  @spec default_poll_interval_ms() :: pos_integer()
  def default_poll_interval_ms, do: @default_poll_interval_ms

  @spec next_interval_ms(pos_integer()) :: pos_integer()
  def next_interval_ms(current) when is_integer(current) and current > 0 do
    trunc(min(@max_poll_interval_ms, current * @poll_backoff))
  end

  defp do_poll(device, attempts, opts) do
    url =
      @poll_url
      |> URI.parse()
      |> Map.put(
        :query,
        URI.encode_query(%{"uuid" => device.uuid, "verifier" => device.verifier})
      )
      |> URI.to_string()

    case http_get(url, opts) do
      {:ok, %{status: 404}} ->
        {:pending, bump_pending(device, attempts, 0)}

      {:ok, %{ok?: true, body: body}} ->
        credentials_from_token_response(body, nil, opts)

      {:ok, %{status: status} = response} when status in [401, 403] ->
        {:error, request_failure("authorization poll", response)}

      {:ok, response} ->
        consecutive = device.consecutive_errors + 1

        if consecutive >= @max_consecutive_errors do
          {:error, request_failure("authorization poll", response)}
        else
          {:pending, bump_pending(device, attempts, consecutive)}
        end

      {:error, message} ->
        consecutive = device.consecutive_errors + 1

        if consecutive >= @max_consecutive_errors do
          {:error, message}
        else
          {:pending, bump_pending(device, attempts, consecutive)}
        end
    end
  end

  defp bump_pending(device, attempts, consecutive_errors) do
    %{
      device
      | attempts: attempts,
        consecutive_errors: consecutive_errors,
        interval_ms: next_interval_ms(device.interval_ms)
    }
  end

  defp credentials_from_token_response(body, previous_refresh, opts) do
    with {:ok, access} <- required_string(body, "accessToken"),
         {:ok, refresh} <- refresh_token_from_response(body, previous_refresh) do
      now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
      expires = expiry_ms(access, now_ms)

      {:authorized,
       %{
         type: "oauth",
         access: access,
         refresh: refresh,
         expires: expires
       }}
    else
      {:error, message} -> {:error, message}
    end
  end

  defp refresh_token_from_response(body, previous_refresh) do
    case Map.get(body, "refreshToken") do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ when is_binary(previous_refresh) and previous_refresh != "" ->
        {:ok, previous_refresh}

      _ ->
        required_string(body, "refreshToken")
    end
  end

  defp expiry_ms(access, now_ms) do
    jwt_exp_ms(access) || now_ms + @default_token_lifetime_seconds * 1000 - @refresh_skew_ms
  end

  defp jwt_exp_ms(access) do
    with [_, payload | _] <- String.split(access, ".", parts: 3),
         {:ok, json} <- decode_jwt_payload(payload),
         {:ok, map} <- Handbean.JSON.decode(json),
         exp when is_integer(exp) <- Map.get(map, "exp") do
      exp * 1000 - @refresh_skew_ms
    else
      _ -> nil
    end
  end

  defp decode_jwt_payload(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, json} -> {:ok, json}
      :error -> Base.url_decode64(payload <> padding_for(payload), padding: true)
    end
  end

  defp padding_for(payload) do
    case rem(byte_size(payload), 4) do
      2 -> "=="
      3 -> "="
      _ -> ""
    end
  end

  defp generate_verifier do
    :crypto.strong_rand_bytes(96) |> Base.url_encode64(padding: false)
  end

  defp challenge_from_verifier(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp generate_uuid do
    Ecto.UUID.generate()
  end

  defp max_attempts(opts), do: Keyword.get(opts, :max_attempts, @max_poll_attempts)

  defp http_get(url, opts) do
    req_mod = req_module(opts)

    case req_mod.get(url, headers: [{"accept", "application/json"}]) do
      {:ok, %{status: status, body: body}} ->
        {:ok, %{ok?: status >= 200 and status < 300, status: status, body: normalize_body(body)}}

      {:error, reason} ->
        {:error, "Cursor OAuth request failed: #{inspect(reason)}"}
    end
  end

  defp http_post(url, body, headers, opts) do
    req_mod = req_module(opts)

    case req_mod.post(url, body: body, headers: headers) do
      {:ok, %{status: status, body: body}} ->
        {:ok, %{ok?: status >= 200 and status < 300, status: status, body: normalize_body(body)}}

      {:error, reason} ->
        {:error, "Cursor OAuth request failed: #{inspect(reason)}"}
    end
  end

  defp req_module(opts) do
    Keyword.get(opts, :req_module) ||
      Process.get(:cursor_oauth_req_module) ||
      Application.get_env(:handbean, :cursor_oauth_req_module) ||
      Req
  end

  defp normalize_body(body) when is_map(body), do: stringify_keys(body)

  defp normalize_body(body) when is_binary(body) do
    case Handbean.JSON.decode(body) do
      {:ok, map} when is_map(map) -> stringify_keys(map)
      _ -> %{}
    end
  end

  defp normalize_body(_), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys_value(value)}
      {key, value} -> {key, stringify_keys_value(value)}
    end)
  end

  defp stringify_keys_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_keys_value(value), do: value

  defp required_string(body, field) do
    case Map.get(body, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, "Invalid Cursor OAuth response field: #{field}"}
    end
  end

  defp request_failure(action, %{status: status, body: body}) do
    error = string_or_nil(Map.get(body, "error"))
    description = string_or_nil(Map.get(body, "message") || Map.get(body, "error_description"))
    detail = Enum.reject([error, description], &is_nil/1) |> Enum.join(": ")

    if detail == "" do
      "Cursor OAuth #{action} failed (HTTP #{status})"
    else
      "Cursor OAuth #{action} failed (HTTP #{status}): #{detail}"
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
end
