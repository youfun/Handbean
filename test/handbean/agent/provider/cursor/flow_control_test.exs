defmodule Handbean.Agent.Provider.Cursor.FlowControlTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.Cursor.FlowControl
  alias Handbean.Agent.Provider.Cursor.Transport

  defmodule WindowHTTP do
    def connect(_scheme, _host, _port, _opts) do
      {:ok, %{window: 8, sent: []}}
    end

    def request(conn, _method, _path, _headers, :stream) do
      {:ok, conn, :ref}
    end

    def stream_request_body(%{window: window} = conn, :ref, data) when is_binary(data) do
      if byte_size(data) > window do
        {:error, conn, {:exceeds_window_size, :request, window}}
      else
        {:ok,
         %{
           conn
           | window: window - byte_size(data),
             sent: conn.sent ++ [data]
         }}
      end
    end

    def stream_request_body(conn, :ref, :eof) do
      {:ok, %{conn | sent: conn.sent ++ [:eof]}}
    end

    def stream(conn, {:window, n}) do
      {:ok, %{conn | window: conn.window + n}, []}
    end

    def stream(conn, {:closed_with, responses}) do
      {:error, conn, :stream_closed, responses}
    end

    def stream(conn, _other), do: {:ok, conn, []}
    def close(conn), do: {:ok, conn}
  end

  defmodule WindowHTTP2 do
    def get_window_size(conn, :connection), do: conn.window
    def get_window_size(conn, {:request, _ref}), do: conn.window
    def cancel_request(conn, _ref), do: {:ok, conn}
  end

  test "payload larger than the window is queued then flushed after WINDOW_UPDATE" do
    {:ok, transport} =
      Transport.connect(
        http_mod: WindowHTTP,
        http2_mod: WindowHTTP2,
        host: "example",
        scheme: :http
      )

    {:ok, transport} = Transport.open_run(transport, "tok", [])
    payload = String.duplicate("x", 20)

    assert {:ok, transport} = Transport.send_message(transport, payload)
    assert Transport.queued_bytes(transport) > 0
    assert byte_size(IO.iodata_to_binary(transport.conn.sent)) <= 8

    {:ok, transport, []} = Transport.handle_mint(transport, {:window, 100})
    assert Transport.queued_bytes(transport) == 0
    sent = IO.iodata_to_binary(Enum.reject(transport.conn.sent, &(&1 == :eof)))
    assert byte_size(sent) == byte_size(Handbean.Agent.Provider.Cursor.Connect.encode(payload))
  end

  test "zero window holds data until an update" do
    {:ok, transport} =
      Transport.connect(
        http_mod: WindowHTTP,
        http2_mod: WindowHTTP2,
        host: "example",
        scheme: :http
      )

    {:ok, transport} = Transport.open_run(transport, "tok", [])
    transport = put_in(transport.conn.window, 0)

    assert {:ok, transport} = Transport.send_message(transport, "hello")
    assert Transport.queued_bytes(transport) > 0
    assert transport.conn.sent == []

    {:ok, transport, []} = Transport.handle_mint(transport, {:window, 16})
    assert Transport.queued_bytes(transport) == 0
    refute transport.conn.sent == []
  end

  test "cancel drops the queued bytes" do
    state =
      FlowControl.new()
      |> FlowControl.enqueue(String.duplicate("z", 50))

    cancelled = FlowControl.cancel(state)
    assert FlowControl.empty?(cancelled)
  end

  test "terminal responses returned with a transport error are still delivered" do
    {:ok, transport} =
      Transport.connect(
        http_mod: WindowHTTP,
        http2_mod: WindowHTTP2,
        host: "example",
        scheme: :http
      )

    {:ok, transport} = Transport.open_run(transport, "tok", [])

    responses = [
      {:data, :ref, Handbean.Agent.Provider.Cursor.Connect.encode("final")},
      {:done, :ref}
    ]

    assert {:ok, transport, [{:message, "final"}, :done]} =
             Transport.handle_mint(transport, {:closed_with, responses})

    refute Transport.open?(transport)
  end
end
