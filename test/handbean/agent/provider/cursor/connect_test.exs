defmodule Handbean.Agent.Provider.Cursor.ConnectTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.Cursor.Connect

  test "encodes flags and big-endian length" do
    frame = Connect.encode("hi")
    assert <<0, 2::32-big, "hi">> = frame
  end

  test "decodes split frames from a leftover buffer" do
    first = Connect.encode("ab")
    second = Connect.encode("cde")
    <<partial::binary-size(4), rest::binary>> = first <> second

    assert {:ok, [], leftover} = Connect.decode_all(partial)
    assert leftover == partial
    assert {:ok, [{:message, "ab"}, {:message, "cde"}], ""} = Connect.decode_all(leftover <> rest)
  end

  test "end-stream JSON error is surfaced" do
    assert {:error, "nope"} = Connect.end_stream_error(~s({"error":{"message":"nope"}}))
  end

  test "compressed frames are rejected" do
    frame = <<1, 1::32-big, "x">>
    assert {{:error, :compressed_unsupported}, _} = Connect.decode_all(frame)
  end
end
