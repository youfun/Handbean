defmodule Handbean.WebPush.ProtocolTest do
  use ExUnit.Case, async: true

  alias Handbean.JSON
  alias Handbean.WebPush.Protocol

  doctest Protocol

  # RFC 8291 section 5 and appendix A: fixed sender/receiver keys and salt.
  @sender %{
    public_key:
      "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIg" <>
        "Dll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
    private_key: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  }
  @receiver %{
    "p256dh" =>
      "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx" <>
        "aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    "auth" => "BTBZMqHH6r4Tts7J_aSIgg"
  }
  @receiver_private "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @plaintext "When I grow up, I want to be a watermelon"
  @endpoint "https://fcm.googleapis.com/fcm/send/private-subscription?key=opaque"
  @subject "mailto:push@example.com"

  test "matches the complete RFC 8291 ciphertext byte for byte" do
    assert {:ok, encrypted} =
             Protocol.encrypt(@plaintext, @receiver, salt: decode(@salt), key_pair: @sender)

    expected =
      "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" <>
        "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" <>
        "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

    assert encrypted == decode(expected)
    # RFC erratum 5230 corrects the printed Content-Length from 145 to 144.
    assert byte_size(encrypted) == 144
    assert decrypt(encrypted) == @plaintext <> <<2>>
  end

  test "generates valid, distinct canonical P-256 key pairs" do
    first = Protocol.generate_key_pair()
    second = Protocol.generate_key_pair()

    assert :ok == Protocol.validate_key_pair(first)
    assert :ok == Protocol.validate_key_pair(second)
    assert first != second
    assert <<4, _coordinates::binary-size(64)>> = decode(first.public_key)
    assert byte_size(decode(first.private_key)) == 32
    refute String.contains?(first.public_key <> first.private_key, ["=", "+", "/"])

    assert :ok ==
             Protocol.validate_key_pair(%{
               "public_key" => first.public_key,
               "private_key" => first.private_key
             })
  end

  test "preserves leading zero bytes in valid private scalars" do
    private = <<1::256>>
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1, private)
    pair = %{public_key: encode(public), private_key: encode(private)}

    assert :ok == Protocol.validate_key_pair(pair)
    assert {:ok, encrypted} = Protocol.encrypt("leading zeros", @receiver, key_pair: pair)
    assert decrypt(encrypted) == "leading zeros" <> <<2>>
    assert {:ok, authorization} = Protocol.authorization(@endpoint, pair, @subject)
    {_header, _claims, ^public} = verify_authorization(authorization)
  end

  test "uses fresh encryption salt and ephemeral keys for every message" do
    assert {:ok, first} = Protocol.encrypt("same message", @receiver)
    assert {:ok, second} = Protocol.encrypt("same message", @receiver)

    assert <<first_salt::binary-size(16), 4096::32, 65, first_key::binary-size(65), _::binary>> =
             first

    assert <<second_salt::binary-size(16), 4096::32, 65, second_key::binary-size(65), _::binary>> =
             second

    assert first_salt != second_salt
    assert first_key != second_key
    assert decrypt(first) == "same message" <> <<2>>
    assert decrypt(second) == "same message" <> <<2>>
  end

  test "supports empty, binary, UTF-8, and maximum-sized plaintext in one record" do
    for plaintext <- ["", <<0, 255, 2, 0>>, "通知已就绪", :binary.copy(<<255>>, 3993)] do
      assert {:ok, encrypted} = Protocol.encrypt(plaintext, @receiver)
      assert byte_size(encrypted) == byte_size(plaintext) + 103
      assert byte_size(encrypted) <= 4096
      assert decrypt(encrypted) == plaintext <> <<2>>
    end

    assert {:error, :payload_too_large} ==
             Protocol.encrypt(String.duplicate("x", 3994), @receiver)

    assert {:error, :payload_too_large} ==
             Protocol.encrypt(String.duplicate("中", 1332), @receiver)

    for payload <- [nil, [], %{}, 42] do
      assert {:error, :invalid_payload} == Protocol.encrypt(payload, @receiver)
    end
  end

  test "rejects malformed subscription keys, invalid points, and wrong curves" do
    {other_curve, _private} = :crypto.generate_key(:ecdh, :secp256k1)

    invalid_public = [
      nil,
      42,
      "",
      String.duplicate("a", 10_000),
      @receiver["p256dh"] <> "=",
      "!" <> binary_part(@receiver["p256dh"], 1, 86),
      encode(<<4, 0::512>>),
      encode(<<2, 0::256>>),
      encode(
        <<4, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF::256, 1::256>>
      ),
      encode(other_curve)
    ]

    for public <- invalid_public do
      keys = %{@receiver | "p256dh" => public}
      assert {:error, :invalid_subscription_keys} == Protocol.validate_subscription_keys(keys)
      assert {:error, :invalid_subscription_keys} == Protocol.encrypt("hello", keys)
    end

    for auth <- [nil, false, "", encode(<<0::120>>), encode(<<0::136>>), @receiver["auth"] <> "="] do
      keys = %{@receiver | "auth" => auth}
      assert {:error, :invalid_subscription_keys} == Protocol.encrypt("hello", keys)
    end

    # The final base64 sextet must have zero unused bits.
    assert {:error, :invalid_subscription_keys} ==
             Protocol.validate_subscription_keys(%{
               @receiver
               | "auth" => "BTBZMqHH6r4Tts7J_aSIgh"
             })

    for keys <- [nil, false, [], %{}, %{"p256dh" => @receiver["p256dh"]}] do
      assert {:error, :invalid_subscription_keys} == Protocol.encrypt("hello", keys)
    end
  end

  test "rejects zero, out-of-range, malformed, and mismatched private keys" do
    order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    for private <- [
          nil,
          false,
          "",
          encode(<<0::256>>),
          encode(<<order::256>>),
          encode(:binary.copy(<<255>>, 32)),
          encode(<<1::248>>),
          encode(<<1::264>>),
          @sender.private_key <> "=",
          @receiver_private
        ] do
      pair = %{@sender | private_key: private}
      assert {:error, :invalid_key_pair} == Protocol.validate_key_pair(pair)
      assert {:error, :invalid_key_pair} == Protocol.encrypt("hello", @receiver, key_pair: pair)
      assert {:error, :invalid_key_pair} == Protocol.authorization(@endpoint, pair, @subject)
    end

    for pair <- [nil, [], %{}, Map.delete(@sender, :public_key), %{@sender | public_key: "bad"}] do
      assert {:error, :invalid_key_pair} == Protocol.validate_key_pair(pair)
    end
  end

  test "rejects malformed encryption options without raising" do
    for opts <- [
          nil,
          %{},
          [:salt],
          [{:salt, <<>>} | :bad],
          [salt: nil],
          [salt: <<0>>],
          [salt: <<0::136>>]
        ] do
      assert {:error, _reason} = Protocol.encrypt("hello", @receiver, opts)
    end

    assert {:error, :invalid_options} == Protocol.encrypt("hello", @receiver, unknown: true)
  end

  test "VAPID uses a verifiable ES256 JWT with origin audience and 12-hour expiration" do
    now = 1_800_000_000
    pair = Protocol.generate_key_pair()
    assert {:ok, authorization} = Protocol.authorization(@endpoint, pair, @subject, now: now)
    {header, claims, public} = verify_authorization(authorization)

    assert header == %{"alg" => "ES256", "typ" => "JWT"}

    assert claims == %{
             "aud" => "https://fcm.googleapis.com",
             "exp" => now + 43_200,
             "sub" => @subject
           }

    assert public == decode(pair.public_key)
    refute String.contains?(authorization, pair.private_key)
  end

  test "VAPID excludes paths, queries, and the default port from the audience" do
    for endpoint <- [
          "https://fcm.googleapis.com/another/token?query=secret",
          "https://FCM.GOOGLEAPIS.COM:443/subscribe/token",
          "https://fcm.googleapis.com"
        ] do
      assert {:ok, authorization} = Protocol.authorization(endpoint, @sender, @subject, now: 100)
      {_header, claims, _public} = verify_authorization(authorization)
      assert claims["aud"] == "https://fcm.googleapis.com"
    end
  end

  test "validates public contact subjects and rejects localhost and loopback HTTPS contacts" do
    for subject <- [@subject, "https://example.com/contact", "https://EXAMPLE.COM/contact"] do
      assert :ok == Protocol.validate_subject(subject)
    end

    for subject <- [
          nil,
          "mailto:invalid",
          "http://example.com/contact",
          "https://localhost",
          "https://LOCALHOST/contact",
          "https://LocalHost.:443/contact",
          "https://127.0.0.1/contact",
          "https://127.0.0.2/contact",
          "https://[::1]/contact",
          "https://[0:0:0:0:0:0:0:1]/contact"
        ] do
      assert {:error, :invalid_subject} == Protocol.validate_subject(subject)
      assert {:error, :invalid_subject} == Protocol.authorization(@endpoint, @sender, subject)
    end
  end

  test "VAPID accepts HTTPS contact subjects and at most 24 hours of validity" do
    assert {:ok, authorization} =
             Protocol.authorization(@endpoint, @sender, "https://example.com/contact",
               now: 100,
               expires_at: 86_500
             )

    {_header, claims, _public} = verify_authorization(authorization)
    assert claims["exp"] == 86_500
    assert claims["sub"] == "https://example.com/contact"

    for expiry <- [99, 100, 86_501, nil, "200", 101.0] do
      assert {:error, :invalid_expiration} ==
               Protocol.authorization(@endpoint, @sender, @subject, now: 100, expires_at: expiry)
    end

    for now <- [nil, -1, "100", 100.0] do
      assert {:error, :invalid_expiration} ==
               Protocol.authorization(@endpoint, @sender, @subject, now: now)
    end
  end

  test "VAPID rejects invalid endpoints, subjects, and options without exposing secrets" do
    assert {:error, :invalid_endpoint} ==
             Protocol.authorization("https://localhost/push", @sender, @subject)

    for subject <- [
          nil,
          42,
          "",
          "http://example.com",
          "mailto:",
          "mailto:invalid",
          "https:///",
          "https://example.com/\r\nheader",
          "mailto:" <> <<255>>,
          String.duplicate("x", 2049)
        ] do
      assert {:error, :invalid_subject} == Protocol.authorization(@endpoint, @sender, subject)
    end

    for opts <- [nil, %{}, [:now], [unknown: true]] do
      assert {:error, :invalid_options} ==
               Protocol.authorization(@endpoint, @sender, @subject, opts)
    end
  end

  defp verify_authorization("vapid t=" <> parameters) do
    [jwt, encoded_public] = String.split(parameters, ", k=")
    [header, body, encoded_signature] = String.split(jwt, ".")
    assert <<r::256, s::256>> = decode(encoded_signature)
    signature = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    public = decode(encoded_public)
    verification_key = {{:ECPoint, public}, {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}}

    assert :public_key.verify(header <> "." <> body, :sha256, signature, verification_key)

    refute :public_key.verify(
             header <> "." <> body <> "tampered",
             :sha256,
             signature,
             verification_key
           )

    {JSON.decode!(decode(header)), JSON.decode!(decode(body)), public}
  end

  defp decrypt(encrypted) do
    <<salt::binary-size(16), record_size::32, 65, sender_public::binary-size(65), record::binary>> =
      encrypted

    assert byte_size(record) < record_size
    receiver_public = decode(@receiver["p256dh"])
    secret = :crypto.compute_key(:ecdh, sender_public, decode(@receiver_private), :prime256v1)
    auth_prk = :crypto.mac(:hmac, :sha256, decode(@receiver["auth"]), secret)
    info = "WebPush: info" <> <<0>> <> receiver_public <> sender_public <> <<1>>
    ikm = :crypto.mac(:hmac, :sha256, auth_prk, info)
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    <<cek::binary-size(16), _::binary>> =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)

    <<nonce::binary-size(12), _::binary>> =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: nonce" <> <<0, 1>>)

    ciphertext_size = byte_size(record) - 16
    <<ciphertext::binary-size(^ciphertext_size), tag::binary-size(16)>> = record
    :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)
  end

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
  defp decode(encoded), do: Base.url_decode64!(encoded, padding: false)
end
