defmodule Handbean.Agent.Provider.Cursor.Transport do
  @moduledoc """
  Mint HTTP/2 client for Cursor `api2.cursor.sh`.

  Outbound Connect frames are queued against the HTTP/2 send window.
  A payload larger than the current window is split; a zero window waits
  for WINDOW_UPDATE processed through `handle_mint/2`. Cancel drops the
  queue instead of sending it later.
  """

  alias Handbean.Agent.Provider.Cursor.{Connect, FlowControl}

  @host "api2.cursor.sh"
  @port 443
  @client_version "cli-2026.01.09-231024f"
  @run_path "/agent.v1.AgentService/Run"
  @models_path "/agent.v1.AgentService/GetUsableModels"
  @available_models_path "/aiserver.v1.AiService/AvailableModels"

  defstruct [
    :conn,
    :ref,
    :buffer,
    :status,
    :open?,
    :http_mod,
    :http2_mod,
    send_queue: %FlowControl{}
  ]

  @type t :: %__MODULE__{}

  def connect(opts \\ []) do
    host = Keyword.get(opts, :host, @host)
    port = Keyword.get(opts, :port, @port)
    scheme = Keyword.get(opts, :scheme, :https)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    http_mod = Keyword.get(opts, :http_mod, Mint.HTTP)

    case http_mod.connect(scheme, host, port,
           protocols: [:http2],
           transport_opts: transport_opts
         ) do
      {:ok, conn} ->
        {:ok,
         %__MODULE__{
           conn: conn,
           buffer: <<>>,
           open?: true,
           http_mod: http_mod,
           http2_mod: Keyword.get(opts, :http2_mod, Mint.HTTP2),
           send_queue: FlowControl.new()
         }}

      {:error, reason} ->
        {:error, "Cursor HTTP/2 connect failed: #{inspect(reason)}"}
    end
  end

  def unary_proto(%__MODULE__{} = transport, path, body, token, opts \\ [])
      when is_binary(body) and is_binary(token) do
    headers = common_headers(token, "application/proto", opts)
    http_mod = http_mod(transport)

    with {:ok, conn, ref} <- http_mod.request(transport.conn, "POST", path, headers, body) do
      await_unary(%{transport | conn: conn, ref: ref, buffer: <<>>, status: nil}, opts)
    else
      {:error, conn, reason} ->
        {:error, %{transport | conn: conn}, "Cursor unary request failed: #{inspect(reason)}"}
    end
  end

  def get_usable_models(transport, token, opts \\ []) do
    unary_proto(transport, @models_path, <<>>, token, opts)
  end

  def available_models(transport, token, opts \\ []) do
    unary_proto(
      transport,
      @available_models_path,
      Handbean.Agent.Provider.Cursor.Proto.encode_available_models_request(),
      token,
      opts
    )
  end

  def open_run(%__MODULE__{} = transport, token, opts \\ []) do
    headers =
      common_headers(token, "application/connect+proto", opts) ++
        [{"connect-protocol-version", "1"}]

    http_mod = http_mod(transport)

    case http_mod.request(transport.conn, "POST", @run_path, headers, :stream) do
      {:ok, conn, ref} ->
        {:ok,
         %{
           transport
           | conn: conn,
             ref: ref,
             buffer: <<>>,
             status: nil,
             open?: true,
             send_queue: FlowControl.new()
         }}

      {:error, conn, reason} ->
        {:error, %{transport | conn: conn}, "Cursor Run request failed: #{inspect(reason)}"}
    end
  end

  def send_message(%__MODULE__{} = transport, payload, opts \\ []) when is_binary(payload) do
    frame = Connect.encode(payload, opts)
    eof? = Keyword.get(opts, :end_stream, false)
    transport = %{transport | send_queue: FlowControl.enqueue(transport.send_queue, frame, eof?)}
    flush(transport)
  end

  def flush(%__MODULE__{conn: nil} = transport), do: {:ok, transport}

  def flush(%__MODULE__{} = transport) do
    window = send_window(transport)
    {ops, queue} = FlowControl.take(transport.send_queue, window)
    flush_ops(%{transport | send_queue: queue}, ops)
  end

  def handle_mint(%__MODULE__{} = transport, message) do
    case http_mod(transport).stream(transport.conn, message) do
      :unknown ->
        {:ok, transport, []}

      {:ok, conn, responses} ->
        case consume_responses(%{transport | conn: conn}, responses, []) do
          {:ok, transport, frames} ->
            case flush(transport) do
              {:ok, transport} -> {:ok, transport, frames}
              {:error, transport, reason} -> {:error, transport, reason}
            end

          other ->
            other
        end

      {:error, conn, reason, responses} ->
        transport = %{transport | conn: conn}

        case consume_responses(transport, responses, []) do
          {:ok, transport, frames} ->
            if terminal_frames?(frames) do
              {:ok, transport, frames}
            else
              transport_error(transport, reason)
            end

          {:error, transport, response_reason} ->
            transport_error(transport, response_reason)
        end
    end
  end

  def cancel(%__MODULE__{conn: conn, ref: ref} = transport) when not is_nil(ref) do
    transport = %{transport | send_queue: FlowControl.cancel(transport.send_queue)}
    http2_mod = http2_mod(transport)

    case http2_mod.cancel_request(conn, ref) do
      {:ok, conn} -> close(%{transport | conn: conn, ref: nil, open?: false})
      {:error, conn, _reason} -> close(%{transport | conn: conn, open?: false})
    end
  end

  def cancel(transport) do
    close(%{
      transport
      | send_queue: FlowControl.cancel(transport.send_queue || FlowControl.new())
    })
  end

  def close(%__MODULE__{conn: nil} = transport), do: %{transport | open?: false}

  def close(%__MODULE__{conn: conn} = transport) do
    case http_mod(transport).close(conn) do
      {:ok, conn} -> %{transport | conn: conn, open?: false, ref: nil}
      {:error, conn, _reason} -> %{transport | conn: conn, open?: false, ref: nil}
    end
  end

  def open?(%__MODULE__{open?: open?}), do: open?

  def queued_bytes(%__MODULE__{send_queue: %FlowControl{queue: queue}}), do: byte_size(queue)
  def queued_bytes(_), do: 0

  defp flush_ops(transport, []), do: {:ok, transport}

  defp flush_ops(transport, [{:data, chunk} | rest]) do
    case stream_chunk(transport, chunk) do
      {:ok, transport} -> flush_ops(transport, rest)
      other -> other
    end
  end

  defp flush_ops(transport, [:eof | rest]) do
    case stream_chunk(transport, :eof) do
      {:ok, transport} -> flush_ops(transport, rest)
      other -> other
    end
  end

  defp stream_chunk(%__MODULE__{conn: conn, ref: ref} = transport, iodata) do
    case http_mod(transport).stream_request_body(conn, ref, iodata) do
      {:ok, conn} ->
        {:ok, %{transport | conn: conn}}

      {:error, conn, reason} ->
        {:error, %{transport | conn: conn}, "Cursor stream send failed: #{inspect(reason)}"}
    end
  end

  defp send_window(%__MODULE__{conn: conn, ref: ref} = transport) do
    http2_mod = http2_mod(transport)

    cond do
      function_exported?(http2_mod, :get_window_size, 2) and not is_nil(ref) ->
        connection = http2_mod.get_window_size(conn, :connection)
        request = http2_mod.get_window_size(conn, {:request, ref})
        max(0, min(connection, request))

      is_map(conn) ->
        Map.get(conn, :window, 65_535)

      true ->
        65_535
    end
  rescue
    _ -> Map.get(transport.conn, :window, 0)
  end

  defp consume_responses(transport, [], frames), do: {:ok, transport, frames}

  defp consume_responses(transport, [{:status, ref, status} | rest], frames)
       when ref == transport.ref do
    consume_responses(%{transport | status: status}, rest, frames)
  end

  defp consume_responses(transport, [{:headers, ref, _headers} | rest], frames)
       when ref == transport.ref do
    consume_responses(transport, rest, frames)
  end

  defp consume_responses(transport, [{:data, ref, data} | rest], frames)
       when ref == transport.ref do
    buffer = transport.buffer <> data

    case Connect.decode_all(buffer) do
      {:ok, decoded, leftover} ->
        consume_responses(%{transport | buffer: leftover}, rest, frames ++ decoded)

      {{:error, reason}, leftover} ->
        {:error, %{transport | buffer: leftover}, inspect(reason)}
    end
  end

  defp consume_responses(transport, [{:done, ref} | rest], frames)
       when ref == transport.ref do
    consume_responses(%{transport | open?: false, ref: nil}, rest, frames ++ [:done])
  end

  defp consume_responses(transport, [{:error, ref, reason} | _rest], _frames)
       when ref == transport.ref do
    {:error, %{transport | open?: false}, inspect(reason)}
  end

  defp consume_responses(transport, [_other | rest], frames) do
    consume_responses(transport, rest, frames)
  end

  defp terminal_frames?(frames) do
    Enum.any?(frames, fn
      :done -> true
      {:end_stream, _payload} -> true
      _ -> false
    end)
  end

  defp transport_error(transport, reason) do
    {:error,
     %{
       transport
       | open?: false,
         send_queue: FlowControl.cancel(transport.send_queue)
     }, inspect(reason)}
  end

  defp await_unary(transport, opts, acc \\ <<>>) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    receive do
      message ->
        case http_mod(transport).stream(transport.conn, message) do
          :unknown ->
            await_unary(transport, opts, acc)

          {:ok, conn, responses} ->
            transport = %{transport | conn: conn}

            case fold_unary(responses, transport, acc) do
              {:cont, transport, acc} -> await_unary(transport, opts, acc)
              other -> other
            end

          {:error, conn, reason, _} ->
            {:error, %{transport | conn: conn}, inspect(reason)}
        end
    after
      timeout ->
        {:error, transport, "Cursor unary request timed out"}
    end
  end

  defp fold_unary([], transport, acc), do: {:cont, transport, acc}

  defp fold_unary([{:status, ref, status} | rest], %{ref: ref} = transport, acc) do
    fold_unary(rest, %{transport | status: status}, acc)
  end

  defp fold_unary([{:headers, ref, _} | rest], %{ref: ref} = transport, acc) do
    fold_unary(rest, transport, acc)
  end

  defp fold_unary([{:data, ref, data} | rest], %{ref: ref} = transport, acc) do
    fold_unary(rest, transport, acc <> data)
  end

  defp fold_unary([{:done, ref} | _], %{ref: ref, status: status} = transport, acc)
       when status in 200..299 do
    {:ok, %{transport | ref: nil}, acc}
  end

  defp fold_unary([{:done, ref} | _], %{ref: ref, status: status} = transport, acc) do
    {:error, %{transport | ref: nil}, "Cursor unary HTTP #{status}: #{inspect_body(acc)}"}
  end

  defp fold_unary([{:error, ref, reason} | _], %{ref: ref} = transport, _acc) do
    {:error, transport, inspect(reason)}
  end

  defp fold_unary([_other | rest], transport, acc), do: fold_unary(rest, transport, acc)

  defp inspect_body(body) when byte_size(body) > 200, do: binary_part(body, 0, 200)
  defp inspect_body(body), do: body

  defp http_mod(%__MODULE__{http_mod: mod}) when not is_nil(mod), do: mod
  defp http_mod(_), do: Mint.HTTP

  defp http2_mod(%__MODULE__{http2_mod: mod}) when not is_nil(mod), do: mod
  defp http2_mod(_), do: Mint.HTTP2

  defp common_headers(token, content_type, opts) do
    request_id = Keyword.get(opts, :request_id, Ecto.UUID.generate())

    [
      {"authorization", "Bearer #{token}"},
      {"content-type", content_type},
      {"te", "trailers"},
      {"x-ghost-mode", "true"},
      {"x-cursor-client-version", Keyword.get(opts, :client_version, @client_version)},
      {"x-cursor-client-type", "cli"},
      {"x-request-id", request_id}
    ]
    |> Enum.uniq_by(&elem(&1, 0))
  end
end
