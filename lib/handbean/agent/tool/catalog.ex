defmodule Handbean.Agent.Tool.Catalog do
  @moduledoc """
  Builds the provider-visible tool set for an agent turn.

  Registry membership, session active sets, run authorization, MCP access,
  deferred loading, and final-turn suppression are combined here so the turn
  state machine only consumes the resulting definitions.
  """

  alias Handbean.Agent.State
  alias Handbean.Agent.Tool.Executor
  alias Handbean.Tool.{Deferred, Registry}

  @final_turn_prompt """
  You have reached the final agent step. Do not call tools. Give the user the best complete answer you can now. Summarize completed work, verification, unresolved items, and the next concrete action when anything remains.
  """

  @spec for_completion(State.t(), keyword(), map()) :: {map(), [map()]}
  def for_completion(%State{} = state, opts, provider_config)
      when is_list(opts) and is_map(provider_config) do
    tool_defs = active_defs(state, opts)
    max_turns = state.config.max_turns
    final_turn? = is_integer(max_turns) and state.turn + 1 >= max_turns

    if final_turn? do
      {require_final_answer(provider_config), []}
    else
      {provider_config, tool_defs}
    end
  end

  @spec active_defs(State.t(), keyword()) :: [map()]
  def active_defs(%State{} = state, opts) when is_list(opts) do
    authorized_tools = Executor.authorized_tools(state.config)
    context = state.config.context || %{}

    eager =
      opts
      |> Keyword.get(:session_id)
      |> session_tool_defs()
      |> Handbean.MCP.Access.filter(context)
      |> Enum.filter(&(&1.name in authorized_tools))
      |> omit_idle_tool_search(context, authorized_tools)
      |> Enum.map(
        &Handbean.Tool.Builtin.Task.contextualize_def(&1, state.config, authorized_tools)
      )

    (eager ++ loaded_tool_defs(state, context, authorized_tools, eager))
    |> Handbean.Agent.Provider.filter_context_tools(state.config.provider)
  end

  defp omit_idle_tool_search(defs, context, authorized_tools) do
    if Enum.any?(defs, &(&1.name == "tool_search")) and
         not Deferred.any?(context, authorized_tools) do
      Enum.reject(defs, &(&1.name == "tool_search"))
    else
      defs
    end
  end

  defp loaded_tool_defs(state, context, authorized_tools, eager) do
    conversation_id = context[:conversation_id]
    eager_names = MapSet.new(eager, & &1.name)
    catalog = Map.new(Registry.deferred_catalog(), &{&1.name, &1})

    conversation_id
    |> Deferred.loaded_names()
    |> Enum.filter(&(Map.has_key?(catalog, &1) and &1 in authorized_tools))
    |> Enum.map(&Map.fetch!(catalog, &1))
    |> Handbean.MCP.Access.filter(context)
    |> Enum.reject(&MapSet.member?(eager_names, &1.name))
    |> Enum.map(&Map.take(&1, [:name, :description, :input_schema]))
    |> Enum.map(&Handbean.Tool.Builtin.Task.contextualize_def(&1, state.config, authorized_tools))
  end

  defp session_tool_defs(nil), do: Registry.tool_defs()
  defp session_tool_defs(session_id), do: Registry.tool_defs_for_session(session_id)

  defp require_final_answer(provider_config) do
    prompt = Map.get(provider_config, :system_prompt) || ""

    Map.put(
      provider_config,
      :system_prompt,
      String.trim_trailing(prompt) <> "\n\n" <> @final_turn_prompt
    )
  end
end
