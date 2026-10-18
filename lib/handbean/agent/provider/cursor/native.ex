defmodule Handbean.Agent.Provider.Cursor.Native do
  @moduledoc """
  Maps Cursor native exec requests onto Handbean tools, or rejects them.

  Advertising MCP tools does not prevent native requests. Mapped calls still
  go through Handbean ToolGuard. Unsupported operations are rejected on the
  matching result field and never executed locally.

  `ShellArgs.timeout` is forwarded unchanged: protobuf documents
  `hard_timeout` as milliseconds but does not annotate `timeout`. Handbean
  bash timeout is seconds; converting without a confirmed source unit is
  refused.
  """

  alias Handbean.Agent.Provider.Cursor.Proto

  @read_names ~w(read)
  @write_names ~w(write)
  @shell_names ~w(bash)
  @grep_names ~w(grep)
  @ls_names ~w(glob)
  @fetch_names ~w(webfetch fetch web_fetch)

  def map(kind, payload, tool_names) when is_list(tool_names) do
    names = MapSet.new(tool_names)

    case kind do
      :read -> map_named(@read_names, names, "read", read_input(payload))
      :write -> map_named(@write_names, names, "write", write_input(payload))
      :shell -> map_named(@shell_names, names, "bash", shell_input(payload))
      :shell_stream -> map_named(@shell_names, names, "bash", shell_input(payload))
      :grep -> map_named(@grep_names, names, "grep", grep_input(payload))
      :ls -> map_named(@ls_names, names, "glob", ls_input(payload))
      :fetch -> map_named(@fetch_names, names, "webfetch", fetch_input(payload))
      :mcp -> {:mcp, payload}
      :request_context -> :context
      :delete -> {:reject, "Handbean does not execute Cursor native delete"}
      :unsupported -> {:reject, "Unsupported Cursor native tool request"}
      _ -> {:reject, "Unsupported Cursor native tool request"}
    end
  end

  def encode_result(kind, output, is_error?) do
    text = output_text(output)

    case {kind, is_error?} do
      {:mcp, true} ->
        Proto.encode_mcp_error(text)

      {:mcp, false} ->
        Proto.encode_mcp_success(text)

      {:read, true} ->
        Proto.encode_native_rejected(7, text)

      {:read, false} ->
        Proto.encode_native_success(7, Proto.encode_read_success(output_path(output), text))

      {:write, true} ->
        Proto.encode_native_rejected(3, text)

      {:write, false} ->
        Proto.encode_native_success(3, Proto.encode_write_success(output_path(output)))

      {:shell, _} ->
        encode_shell_result(text, is_error?)

      {:shell_stream, _} ->
        encode_shell_stream_frames(text, is_error?)

      {:fetch, true} ->
        Proto.encode_native_rejected(20, text)

      {:fetch, false} ->
        Proto.encode_native_success(20, Proto.encode_fetch_success(output_url(output), text))

      {:ls, true} ->
        Proto.encode_native_rejected(8, text)

      {:ls, false} ->
        Proto.encode_native_success(
          8,
          Proto.encode_ls_success(".", String.split(text, "\n", trim: true))
        )

      {:grep, true} ->
        Proto.encode_native_rejected(5, text)

      {:grep, false} ->
        Proto.encode_native_success(5, Proto.encode_string(1, text))

      {other, _} ->
        Proto.encode_native_rejected(result_field(other), text)
    end
  end

  def encode_rejection(kind, message) do
    case kind do
      :mcp -> Proto.encode_mcp_rejected(message)
      :shell_stream -> Proto.encode_shell_stream_rejected(message)
      other -> Proto.encode_native_rejected(result_field(other), message)
    end
  end

  def shell_stream_control?(kind), do: kind == :shell_stream

  defp map_named(candidates, names, default_name, input) do
    case Enum.find(candidates, &MapSet.member?(names, &1)) do
      nil -> {:reject, "No Handbean tool available for Cursor native #{default_name}"}
      name -> {:tool, name, input}
    end
  end

  defp read_input(payload),
    do: %{"file_path" => Handbean.Utils.SafeMap.get_any(payload, :path, "path")}

  defp write_input(payload) do
    content =
      cond do
        is_binary(payload[:file_bytes]) -> payload[:file_bytes]
        true -> payload[:file_text] || ""
      end

    %{"file_path" => payload[:path], "content" => content}
  end

  defp shell_input(payload) do
    %{
      "command" => payload[:command],
      "cwd" => payload[:working_directory],
      "timeout" => payload[:timeout]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp grep_input(payload) do
    %{
      "pattern" => payload[:pattern],
      "path" => payload[:path],
      "glob" => payload[:glob]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp ls_input(payload) do
    %{"query" => "*", "path" => payload[:path] || "."}
  end

  defp fetch_input(payload) do
    %{"url" => payload[:url]}
  end

  defp output_text(output) when is_binary(output), do: output
  defp output_text(%{content: content}) when is_binary(content), do: content
  defp output_text(%{"content" => content}) when is_binary(content), do: content
  defp output_text(other), do: to_string(other)

  defp output_path(%{"file_path" => path}), do: path
  defp output_path(%{file_path: path}), do: path
  defp output_path(_), do: ""

  defp output_url(%{"url" => url}), do: url
  defp output_url(%{url: url}), do: url
  defp output_url(_), do: ""

  defp encode_shell_result(text, true), do: Proto.encode_native_rejected(2, text)

  defp encode_shell_result(text, false) do
    Proto.encode_native_success(2, Proto.encode_shell_success("", text, "", 0))
  end

  defp encode_shell_stream_frames(text, true) do
    [{:stream, Proto.encode_shell_stream_rejected(text)}, :stream_close]
  end

  defp encode_shell_stream_frames(text, false) do
    frames = [{:stream, Proto.encode_shell_stream_start()}]

    frames =
      if text == "" do
        frames
      else
        frames ++ [{:stream, Proto.encode_shell_stream_stdout(text)}]
      end

    frames ++ [{:stream, Proto.encode_shell_stream_exit(0)}, :stream_close]
  end

  defp result_field(:shell), do: 2
  defp result_field(:write), do: 3
  defp result_field(:delete), do: 4
  defp result_field(:grep), do: 5
  defp result_field(:read), do: 7
  defp result_field(:ls), do: 8
  defp result_field(:fetch), do: 20
  defp result_field(:unsupported), do: 2
  defp result_field(_), do: 2
end
