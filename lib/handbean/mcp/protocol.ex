defmodule Handbean.MCP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 encoding/decoding for MCP protocol messages.

  Handles message framing over stdio (newline-delimited JSON).
  """

  @doc """
  Encodes a JSON-RPC 2.0 request as a newline-terminated binary.
  """
  @spec encode_request(binary(), binary(), map(), keyword()) :: binary()
  def encode_request(id, method, params \\ %{}, _opts \\ []) do
    %{
      jsonrpc: "2.0",
      id: id,
      method: method,
      params: params
    }
    |> Handbean.JSON.encode!()
    |> then(&(&1 <> "\n"))
  end

  @doc """
  Encodes a JSON-RPC 2.0 notification (no id).
  """
  @spec encode_notification(binary(), map()) :: binary()
  def encode_notification(method, params \\ %{}) do
    %{
      jsonrpc: "2.0",
      method: method,
      params: params
    }
    |> Handbean.JSON.encode!()
    |> then(&(&1 <> "\n"))
  end

  @doc """
  Parses a JSON-RPC 2.0 response map, returning {:ok, result} or {:error, error_struct}.
  """
  @spec parse_response(map()) :: {:ok, term()} | {:error, map()}
  def parse_response(%{"result" => result}), do: {:ok, result}
  def parse_response(%{"error" => error}), do: {:error, error}
  def parse_response(_), do: {:error, %{"code" => -32_600, "message" => "Invalid response"}}

  @doc """
  Splits a binary buffer into complete JSON lines and remaining partial data.
  """
  @spec split_lines(binary()) :: {[binary()], binary()}
  def split_lines(data) do
    case String.split(data, "\n", trim: false) do
      [] ->
        {[], ""}

      parts ->
        {complete, [rest]} = Enum.split(parts, -1)
        {Enum.reject(complete, &(&1 == "")), rest}
    end
  end

  @doc """
  Decodes JSON lines into maps.
  """
  @spec decode_lines([binary()]) :: {:ok, [map()]} | {:error, term()}
  def decode_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Handbean.JSON.decode(line) do
        {:ok, %{} = msg} -> {:cont, {:ok, [msg | acc]}}
        {:ok, _} -> {:halt, {:error, :invalid_message}}
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  @legacy_versions ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
  @modern_version "2026-07-28"
  @supported_versions [@modern_version | @legacy_versions]

  @doc """
  Protocol version sent on a stateless `2026-07-28` request.
  """
  @spec modern_version() :: binary()
  def modern_version, do: @modern_version

  @doc """
  Newest handshake revision advertised to a legacy server.
  """
  @spec latest_legacy_version() :: binary()
  def latest_legacy_version, do: "2025-11-25"

  @doc """
  Versions Handbean can continue with after the server picks one.
  """
  @spec supported_version?(binary()) :: boolean()
  def supported_version?(version) when is_binary(version), do: version in @supported_versions
  def supported_version?(_), do: false

  @doc """
  Handshake revisions. `2026-07-28` is not negotiated through `initialize`.
  """
  @spec legacy_version?(binary()) :: boolean()
  def legacy_version?(version) when is_binary(version), do: version in @legacy_versions
  def legacy_version?(_), do: false

  @doc """
  Generates a unique request ID (combination of timestamp + random).
  """
  @spec generate_id() :: binary()
  def generate_id do
    "#{:erlang.system_time(:millisecond)}-#{:rand.uniform(999_999)}"
  end
end
