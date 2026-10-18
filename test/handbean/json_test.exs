defmodule Handbean.JSONTest do
  use ExUnit.Case, async: true

  alias Handbean.JSON

  test "encodes and decodes Elixir values with OTP json" do
    value = %{
      "boolean" => true,
      "null" => nil,
      "atom" => :ready,
      "tuple" => {:ok, 2},
      "time" => ~U[2026-08-20 00:00:00Z]
    }

    assert {:ok, encoded} = JSON.encode(value)

    assert JSON.decode!(encoded) == %{
             "boolean" => true,
             "null" => nil,
             "atom" => "ready",
             "tuple" => ["ok", 2],
             "time" => "2026-08-20T00:00:00Z"
           }
  end

  test "supports pretty output and Phoenix iodata" do
    assert JSON.encode!(%{answer: 42}, pretty: true) == "{ \"answer\": 42 }\n"
    assert JSON.encode_to_iodata!(%{answer: 42}) |> IO.iodata_to_binary() == ~s({"answer":42})
  end

  test "returns errors for malformed JSON" do
    assert {:error, %ErlangError{}} = JSON.decode("{")
  end

  test "is the Phoenix JSON adapter" do
    assert Phoenix.json_library() == JSON
  end
end
