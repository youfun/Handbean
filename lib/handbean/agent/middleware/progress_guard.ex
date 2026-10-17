defmodule Handbean.Agent.Middleware.ProgressGuard do
  @moduledoc false

  @behaviour Handbean.Agent.Middleware

  alias Handbean.Agent.{Message, ProgressGuard, State}

  @impl true
  def call(:after_tool_execution, %State{} = state) do
    advisor = state.advisor || %{}

    cond do
      not ProgressGuard.enabled?(state.config) ->
        state

      advisor[:phase] == :reviewing ->
        state

      true ->
        state
        |> observations()
        |> Enum.uniq_by(&ProgressGuard.observation_key/1)
        |> Enum.reduce(state, fn obs, acc ->
          case ProgressGuard.observe(acc.progress, obs) do
            {progress, nil, nil} ->
              %{acc | progress: progress}

            {progress, signal, evidence} ->
              stall(acc, progress, signal, evidence)
          end
        end)
    end
  end

  def call(_hook, state), do: state

  defp stall(%State{status: status} = state, progress, _signal, _evidence)
       when status != :running do
    %{state | progress: progress}
  end

  defp stall(state, progress, signal, evidence) do
    if ProgressGuard.interactive?(state.config) do
      %{
        state
        | progress: progress,
          status: :interrupted,
          interrupt_data: %{
            type: :stall_check,
            signal: signal,
            evidence: evidence,
            turn: state.turn
          }
      }
    else
      %{
        state
        | progress: progress,
          status: :stalled,
          error: evidence,
          interrupt_data: %{type: :stall_check, signal: signal, evidence: evidence}
      }
    end
  end

  defp observations(%State{messages: messages}) do
    uses =
      messages
      |> Enum.flat_map(&tool_uses/1)
      |> Map.new(fn block -> {block_id(block), block} end)

    case List.last(messages) do
      %Message{role: :tool_result, content: blocks} when is_list(blocks) ->
        Enum.flat_map(blocks, fn block ->
          case Map.get(uses, block_id(block)) do
            nil ->
              []

            use ->
              [
                %{
                  tool: block_value(use, :name) || "tool",
                  args: block_value(use, :input) || %{},
                  result: to_string(block_value(block, :content) || ""),
                  error: block_value(block, :is_error) == true,
                  path: path_of(use)
                }
              ]
          end
        end)

      _ ->
        []
    end
  end

  defp tool_uses(%Message{content: blocks}) when is_list(blocks) do
    Enum.filter(blocks, &(block_value(&1, :type) == "tool_use"))
  end

  defp tool_uses(_), do: []

  defp path_of(use) do
    input = block_value(use, :input) || %{}

    Handbean.Utils.SafeMap.get_any(input, "file_path", "path") ||
      Handbean.Utils.SafeMap.get_any(input, :file_path, :path)
  end

  defp block_id(block), do: block_value(block, :id) || block_value(block, :tool_use_id)

  defp block_value(block, key) when is_map(block) do
    Map.get(block, key) || Map.get(block, Atom.to_string(key))
  end
end
