defmodule Handbean.WebPush.Protocol do
  @moduledoc """
  Web Push encryption (RFC 8291) and VAPID authentication (RFC 8292).

  Keys use canonical, unpadded base64url. Public keys are uncompressed P-256
  points; private keys are 32-byte scalars. Encryption generates a fresh ECDH
  key pair for each message, independent of the persistent VAPID signing key.
  This module performs no HTTP requests and never logs key material.
  """

  alias Handbean.JSON
  alias Handbean.WebPush.Endpoint

  @curve :prime256v1
  @field 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @curve_b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
  @order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @max_payload_bytes 3993
  @record_size 4096
  @default_lifetime 43_200
  @max_lifetime 86_400

  @type key_pair :: %{public_key: binary(), private_key: binary()}

  @doc """
  Generates a P-256 key pair suitable for VAPID registration and signing.

      iex> pair = Handbean.WebPush.Protocol.generate_key_pair()
      iex> Handbean.WebPush.Protocol.validate_key_pair(pair)
      :ok
  """
  @spec generate_key_pair() :: key_pair()
  def generate_key_pair do
    {public, private} = :crypto.generate_key(:ecdh, @curve)
    %{public_key: encode(public), private_key: encode(private)}
  end

  @doc """
  Validates subscription keys, including the P-256 curve point and auth size.

      iex> Handbean.WebPush.Protocol.validate_subscription_keys(%{})
      {:error, :invalid_subscription_keys}
  """
  @spec validate_subscription_keys(term()) :: :ok | {:error, :invalid_subscription_keys}
  def validate_subscription_keys(keys) do
    with {:ok, _public, _auth} <- subscription_keys(keys), do: :ok
  end

  @doc """
  Validates key sizes, the private scalar range, and public/private agreement.

      iex> Handbean.WebPush.Protocol.validate_key_pair(%{})
      {:error, :invalid_key_pair}
  """
  @spec validate_key_pair(term()) :: :ok | {:error, :invalid_key_pair}
  def validate_key_pair(pair) do
    with {:ok, _public, _private} <- decode_key_pair(pair), do: :ok
  end

  @doc """
  Validates the mailto or HTTPS contact URI used as the VAPID subject.

  HTTPS contacts cannot use localhost or a loopback IP address, which push
  services including Apple reject. Hostname comparisons are case-insensitive.

      iex> Handbean.WebPush.Protocol.validate_subject("https://example.com/contact")
      :ok

      iex> Handbean.WebPush.Protocol.validate_subject("https://LOCALHOST/contact")
      {:error, :invalid_subject}
  """
  @spec validate_subject(term()) :: :ok | {:error, :invalid_subject}
  def validate_subject(subject) when is_binary(subject) and byte_size(subject) in 1..2048 do
    with true <- String.valid?(subject),
         false <- Regex.match?(~r/[\x00-\x20\x7f]/, subject),
         {:ok, uri} <- URI.new(subject),
         true <- contact_uri?(uri) do
      :ok
    else
      _ -> {:error, :invalid_subject}
    end
  end

  def validate_subject(_subject), do: {:error, :invalid_subject}

  @doc """
  Encrypts up to 3993 plaintext bytes as a single aes128gcm record.

  `:salt` (16 raw bytes) and `:key_pair` (encoded keys) can be supplied for
  reproducible protocol vectors. Production callers should omit both options
  to obtain fresh random encryption material for every message.

      iex> Handbean.WebPush.Protocol.encrypt("hello", %{})
      {:error, :invalid_subscription_keys}
  """
  @spec encrypt(term(), term(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def encrypt(payload, keys, opts \\ [])

  def encrypt(payload, _keys, _opts)
      when is_binary(payload) and byte_size(payload) > @max_payload_bytes,
      do: {:error, :payload_too_large}

  def encrypt(payload, keys, opts) when is_binary(payload) do
    with :ok <- validate_options(opts, [:salt, :key_pair]),
         {:ok, receiver_public, auth} <- subscription_keys(keys),
         {:ok, salt} <- encryption_salt(opts),
         {:ok, sender_public, sender_private} <- encryption_key_pair(opts) do
      encrypt_record(payload, receiver_public, auth, salt, sender_public, sender_private)
    end
  end

  def encrypt(_payload, _keys, _opts), do: {:error, :invalid_payload}

  @doc """
  Signs a VAPID Authorization header for a supported push endpoint.

  `:now` and `:expires_at` are Unix timestamps in seconds. Expiration defaults
  to 12 hours and must be in the future, at most 24 hours from `:now`. The
  subject must be a mailto or HTTPS contact URI.

      iex> Handbean.WebPush.Protocol.authorization("http://localhost", %{}, "mailto:a@example.com")
      {:error, :invalid_endpoint}
  """
  @spec authorization(term(), term(), term(), keyword()) ::
          {:ok, binary()} | {:error, atom()}
  def authorization(endpoint, pair, subject, opts \\ []) do
    with :ok <- Endpoint.validate(endpoint),
         :ok <- validate_options(opts, [:now, :expires_at]),
         :ok <- validate_subject(subject),
         {:ok, public, private} <- decode_key_pair(pair),
         {:ok, expires_at} <- expiration(opts) do
      uri = URI.parse(endpoint)
      audience = "https://" <> String.downcase(uri.host)
      claims = %{"aud" => audience, "exp" => expires_at, "sub" => subject}
      sign_token(claims, public, private)
    end
  end

  defp subscription_keys(%{"p256dh" => public, "auth" => auth}) do
    with {:ok, public} <- decode(public, 65),
         true <- valid_public_key?(public),
         {:ok, auth} <- decode(auth, 16) do
      {:ok, public, auth}
    else
      _ -> {:error, :invalid_subscription_keys}
    end
  end

  defp subscription_keys(_keys), do: {:error, :invalid_subscription_keys}

  defp decode_key_pair(%{"public_key" => public, "private_key" => private}),
    do: decode_key_pair(%{public_key: public, private_key: private})

  defp decode_key_pair(%{public_key: public, private_key: private}) do
    with {:ok, public} <- decode(public, 65),
         true <- valid_public_key?(public),
         {:ok, private} <- decode(private, 32),
         true <- valid_private_key?(private),
         {^public, ^private} <- :crypto.generate_key(:ecdh, @curve, private) do
      {:ok, public, private}
    else
      _ -> {:error, :invalid_key_pair}
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :invalid_key_pair}
  end

  defp decode_key_pair(_pair), do: {:error, :invalid_key_pair}

  defp valid_public_key?(<<4, x::unsigned-big-256, y::unsigned-big-256>>) do
    x < @field and y < @field and
      Integer.mod(y * y, @field) == Integer.mod(x * x * x - 3 * x + @curve_b, @field)
  end

  defp valid_public_key?(_public), do: false

  defp valid_private_key?(<<scalar::unsigned-big-256>>), do: scalar > 0 and scalar < @order

  defp decode(encoded, size) when is_binary(encoded) do
    with true <- byte_size(encoded) == div(size * 8 + 5, 6),
         {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(decoded) == size and encode(decoded) == encoded do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp decode(_encoded, _size), do: :error

  defp encode(binary), do: Base.url_encode64(binary, padding: false)

  defp validate_options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(opts, fn {key, _value} -> key in allowed end) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp validate_options(_opts, _allowed), do: {:error, :invalid_options}

  defp encryption_salt(opts) do
    case Keyword.fetch(opts, :salt) do
      :error -> {:ok, :crypto.strong_rand_bytes(16)}
      {:ok, salt} when is_binary(salt) and byte_size(salt) == 16 -> {:ok, salt}
      _ -> {:error, :invalid_salt}
    end
  end

  defp encryption_key_pair(opts) do
    case Keyword.fetch(opts, :key_pair) do
      :error ->
        {public, private} = :crypto.generate_key(:ecdh, @curve)
        {:ok, public, private}

      {:ok, pair} ->
        decode_key_pair(pair)
    end
  end

  defp encrypt_record(payload, receiver_public, auth, salt, sender_public, sender_private) do
    shared = :crypto.compute_key(:ecdh, receiver_public, sender_private, @curve)
    prk_key = hmac(auth, shared)
    ikm = hmac(prk_key, "WebPush: info" <> <<0>> <> receiver_public <> sender_public <> <<1>>)
    prk = hmac(salt, ikm)
    cek = binary_part(hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
    nonce = binary_part(hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, payload <> <<2>>, <<>>, 16, true)

    {:ok,
     salt <>
       <<@record_size::unsigned-big-32, 65>> <>
       sender_public <> ciphertext <> tag}
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :encryption_failed}
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp expiration(opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    if is_integer(now) and now >= 0 do
      expires_at = Keyword.get(opts, :expires_at, now + @default_lifetime)

      if is_integer(expires_at) and expires_at > now and expires_at <= now + @max_lifetime do
        {:ok, expires_at}
      else
        {:error, :invalid_expiration}
      end
    else
      {:error, :invalid_expiration}
    end
  end

  defp contact_uri?(%URI{scheme: "mailto", path: path, host: nil, userinfo: nil, fragment: nil})
       when is_binary(path),
       do: Regex.match?(~r/\A[^@\s]+@[^@\s]+\z/u, path)

  defp contact_uri?(%URI{scheme: "https", host: host, userinfo: nil, fragment: nil})
       when is_binary(host),
       do: valid_contact_host?(host)

  defp contact_uri?(_uri), do: false

  defp valid_contact_host?(host) do
    normalized = host |> String.downcase() |> String.trim_trailing(".")

    normalized not in ["", "localhost"] and
      case :inet.parse_strict_address(String.to_charlist(normalized)) do
        {:ok, {127, _b, _c, _d}} -> false
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> false
        _ -> true
      end
  end

  defp sign_token(claims, public, private) do
    header = encode(JSON.encode!(%{"typ" => "JWT", "alg" => "ES256"}))
    body = encode(JSON.encode!(claims))
    signing_input = header <> "." <> body
    der = :crypto.sign(:ecdsa, :sha256, signing_input, [private, @curve])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    signature = encode(<<r::unsigned-big-256, s::unsigned-big-256>>)
    {:ok, "vapid t=" <> signing_input <> "." <> signature <> ", k=" <> encode(public)}
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :signing_failed}
  end
end
