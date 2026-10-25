defmodule Handbean.Agent.SecretMaskingTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.SecretMasking

  @secret "sk-proj-abcdefghijklmnopqrstuvwxyz123456"

  test "detects high-confidence secrets without treating variables as values" do
    assert [%{kind: "API_KEY", value: @secret}] =
             SecretMasking.detect("token: #{@secret}")

    assert [%{kind: "PASSWORD", value: "hunter2pass"}] =
             SecretMasking.detect("postgres://app:hunter2pass@localhost/db")

    assert [] = SecretMasking.detect("api_key = process.env.OPENAI_API_KEY")
    assert [] = SecretMasking.detect("password = ${DATABASE_PASSWORD}")
    assert [] = SecretMasking.detect("ordinary prose without a credential")
  end

  test "generates stable placeholders and lengthens a colliding suffix" do
    key = :crypto.strong_rand_bytes(32)

    assert {:ok, first} = SecretMasking.placeholder("API_KEY", @secret, key, %{})
    assert {:ok, ^first} = SecretMasking.placeholder("API_KEY", @secret, key, %{first => @secret})

    assert {:ok, extended} =
             SecretMasking.placeholder("API_KEY", @secret, key, %{first => "another-secret"})

    assert byte_size(extended) > byte_size(first)
    assert String.starts_with?(extended, String.trim_trailing(first, "}"))
  end

  test "restores only placeholders owned by the invocation" do
    restore = %{"{{API_KEY_abcdefgh}}" => @secret}

    assert SecretMasking.restore(
             "known={{API_KEY_abcdefgh}} unknown={{API_KEY_ijklmnop}}",
             restore
           ) == "known=#{@secret} unknown={{API_KEY_ijklmnop}}"
  end

  test "restores known placeholders after common model formatting changes" do
    restore = %{"{{API_KEY_abcdefgh}}" => @secret}

    for altered <- [
          "{{api_key_ABCDEFGH}}",
          "{{ API_KEY_abcdefgh }}",
          "{{API_KEY_abcdefgh}",
          "{API_KEY_abcdefgh}}",
          "API_KEY_abcdefgh"
        ] do
      assert SecretMasking.restore("before #{altered} after", restore) ==
               "before #{@secret} after"
    end

    assert SecretMasking.restore("xAPI_KEY_abcdefgh", restore) == "xAPI_KEY_abcdefgh"
    assert SecretMasking.restore("{{API_KEY_ijklmnop}}", restore) == "{{API_KEY_ijklmnop}}"
  end

  test "recognizes a possible placeholder split at the end of a chunk" do
    assert SecretMasking.partial_placeholder_length("prefix {{API_") == 6
    assert SecretMasking.partial_placeholder_length("complete {{API_KEY_abcdefgh}}") == 0
    assert SecretMasking.partial_placeholder_length("") == 0
  end

  test "recognizes request-owned placeholders without braces at a chunk boundary" do
    restore = %{"{{API_KEY_abcdefgh}}" => @secret}

    assert SecretMasking.partial_placeholder_length("prefix API_KEY_ab", restore) == 10
    assert SecretMasking.partial_placeholder_length("ordinary suffix", restore) == 0
  end
end
