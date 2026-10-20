defmodule Handbean.Agent.Turn.Completion do
  @moduledoc false

  alias Handbean.Agent.Message

  def missing_final_answer?(messages) do
    assistant_messages = Enum.filter(messages, &match?(%Message{role: :assistant}, &1))

    cond do
      assistant_messages == [] ->
        false

      Enum.any?(assistant_messages, &final_answer?/1) ->
        false

      Enum.any?(assistant_messages, &(Message.tool_calls(&1) != [])) ->
        false

      true ->
        Enum.all?(assistant_messages, fn message ->
          commentary_only?(message) or not visible_assistant_text?(message)
        end)
    end
  end

  def missing_final_answer_error(messages) do
    if commentary_only_turn?(messages),
      do: "Provider ended the turn without a final answer",
      else: "Provider ended the turn with no visible assistant response or tool call"
  end

  def artifact_digest(state) do
    state.messages
    |> Enum.map_join("\n", &Message.text/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp final_answer?(%Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn block ->
      is_map(block) and block[:type] == "text" and block[:phase] == "final_answer" and
        is_binary(block[:text]) and String.trim(block[:text]) != ""
    end)
  end

  defp final_answer?(%Message{content: text}) when is_binary(text), do: String.trim(text) != ""
  defp final_answer?(_), do: false

  defp commentary_only?(%Message{content: blocks}) when is_list(blocks) do
    text_blocks = Enum.filter(blocks, &(is_map(&1) and &1[:type] == "text"))

    text_blocks != [] and
      Enum.all?(text_blocks, fn block ->
        block[:phase] == "commentary" and is_binary(block[:text]) and
          String.trim(block[:text]) != ""
      end)
  end

  defp commentary_only?(_), do: false

  defp commentary_only_turn?(messages) do
    messages != [] and Enum.all?(messages, &commentary_only?/1)
  end

  defp visible_assistant_text?(%Message{} = message) do
    case Message.text(message) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end
end
