defmodule Handbean.Preview.URL do
  @moduledoc """
  Trusted PreviewShell URL checks.

  Top-level native display may only load the workbench PreviewShell.
  Generated content stays in the sandboxed iframe.
  """

  @spec preview_shell?(URI.t() | String.t(), keyword()) :: boolean()
  def preview_shell?(url, opts \\ [])

  def preview_shell?(url, opts) when is_binary(url) do
    preview_shell?(URI.parse(url), opts)
  end

  def preview_shell?(%URI{} = uri, opts) do
    allowed_port = Keyword.get(opts, :liveview_port)
    expected_id = Keyword.get(opts, :preview_id)

    loopback?(uri) and scheme_http?(uri) and matching_port?(uri, allowed_port) and
      shell_path?(uri.path, expected_id)
  end

  @spec return_conversation_id(URI.t() | String.t()) :: {:ok, String.t()} | :error
  def return_conversation_id(url) when is_binary(url) do
    return_conversation_id(URI.parse(url))
  end

  def return_conversation_id(%URI{scheme: "handbean", host: "c", path: path})
      when is_binary(path) do
    case String.trim_leading(path, "/") do
      id when byte_size(id) > 0 -> {:ok, id}
      _ -> :error
    end
  end

  def return_conversation_id(%URI{scheme: "handbean", host: host, path: path})
      when is_binary(host) and is_binary(path) do
    # handbean://c/<id> sometimes parses host as "c" and path as "/id".
    :error
  end

  def return_conversation_id(%URI{scheme: "handbean", path: path, host: nil})
      when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["c", id] -> {:ok, id}
      _ -> :error
    end
  end

  def return_conversation_id(_), do: :error

  defp loopback?(%URI{host: host}) when host in ["127.0.0.1", "localhost", "::1"], do: true
  defp loopback?(_), do: false

  defp scheme_http?(%URI{scheme: scheme}) when scheme in ["http", "https"], do: true
  defp scheme_http?(_), do: false

  defp matching_port?(_uri, nil), do: true
  defp matching_port?(%URI{port: port}, allowed) when is_integer(allowed), do: port == allowed
  defp matching_port?(_, _), do: false

  defp shell_path?(path, nil) when is_binary(path) do
    match?(["preview", _id], String.split(path, "/", trim: true))
  end

  defp shell_path?(path, preview_id) when is_binary(path) and is_binary(preview_id) do
    String.split(path, "/", trim: true) == ["preview", preview_id]
  end

  defp shell_path?(_, _), do: false
end
