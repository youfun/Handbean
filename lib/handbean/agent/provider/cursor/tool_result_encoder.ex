defmodule Handbean.Agent.Provider.Cursor.ToolResultEncoder do
  @moduledoc """
  Extracts tool results and encodes their ordered Cursor client payloads.

  Sending remains the session owner's responsibility so the first transport
  failure stops the write sequence and drives the session's uncertainty state.
  """

  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.Cursor.{Native, Proto}

  def from_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn
      %Message{role: :tool_result, content: content} -> List.wrap(content)
      %Message{content: content} when is_list(content) -> content
      _ -> []
    end)
    |> Enum.filter(fn
      %{type: "tool_result"} -> true
      %{"type" => "tool_result"} -> true
      _ -> false
    end)
    |> Map.new(fn block ->
      id = Handbean.Utils.SafeMap.get_any(block, :tool_use_id, "tool_use_id")
      content = Handbean.Utils.SafeMap.get_any(block, :content, "content") || ""
      is_error? = Handbean.Utils.SafeMap.get_any(block, :is_error, "is_error") || false
      {id, {content, is_error?}}
    end)
  end

  def client_payloads(exec, output, is_error?) do
    case Native.encode_result(exec.kind, output, is_error?) do
      frames when is_list(frames) -> Enum.flat_map(frames, &encode_frame(&1, exec))
      payload when is_binary(payload) -> [encode_exec(payload, exec)]
    end
  end

  defp encode_frame({:stream, payload}, exec), do: [encode_exec(payload, exec)]

  defp encode_frame(:stream_close, exec) do
    [Proto.encode_client(%{exec_control: Proto.encode_stream_close(exec.id)})]
  end

  defp encode_frame(_, _exec), do: []

  defp encode_exec(payload, exec) do
    message = Proto.encode_exec_client(exec.id, exec.exec_id, exec.result_field, payload)
    Proto.encode_client(%{exec_client: message})
  end
end
