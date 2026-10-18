defmodule Handbean.Tool.Builtin.Task do
  @moduledoc """
  Delegate work to a named subagent profile.

  Background (default): returns at once; the report arrives later as a
  follow-up message. `background: false` blocks for a short read-only run.
  """
  @behaviour Handbean.Agent.Tool

  alias Handbean.Agent.Delegation
  alias Handbean.Agent.Subagent.ProfileRegistry

  @impl true
  def name, do: "task"

  @impl true
  def description do
    "Delegate a task to a subagent with independent context (parent history is not copied). " <>
      "Supply the task and completion criteria. By default it runs in the background: this call " <>
      "returns a child_conversation_id immediately and the subagent's report arrives later as a " <>
      "follow-up message; do not state conclusions that depend on it before then. Several tasks " <>
      "may run in parallel. Use background: false only for a short read-only lookup whose answer " <>
      "you need now (bounded by min(45s, tool timeout / 2)). Use task_status to list, inspect, " <>
      "message, or cancel subagents. Reports are unverified; review them."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        task: %{type: "string", description: "What the subagent should do, with needed context."},
        criteria: %{type: "string", description: "When the task counts as done."},
        subagent_type: %{
          type: "string",
          description: "Profile name. Defaults to researcher."
        },
        background: %{
          type: "boolean",
          description: "Default true. false blocks for a short read-only run."
        }
      },
      required: ["task", "criteria"],
      additionalProperties: false
    }
  end

  @impl true
  def concurrent?, do: true
  @impl true
  def max_result_chars, do: 24_000

  @impl true
  def execute(%{"task" => task, "criteria" => criteria} = input, context)
      when is_binary(task) and is_binary(criteria) and byte_size(task) <= 16_000 and
             byte_size(criteria) <= 4_000 do
    type = Map.get(input, "subagent_type") || "researcher"

    cond do
      String.trim(task) == "" or String.trim(criteria) == "" ->
        {:error, "task and criteria must be non-empty"}

      not is_binary(type) ->
        {:error, "subagent_type must be a string"}

      not is_boolean(Map.get(input, "background", true)) ->
        {:error, "background must be a boolean"}

      true ->
        mode = if Map.get(input, "background", true), do: :background, else: :sync

        with {:ok, profile} <- ProfileRegistry.fetch(context[:working_directory], type) do
          Delegation.run(input, context, profile, mode)
        end
    end
  end

  def execute(_, _),
    do: {:error, "task (max 16000 bytes) and criteria (max 4000 bytes) are required"}

  @doc """
  Provider-facing definition with the profiles this run can start. The
  static `description/0` cannot know the workspace or authorization.
  """
  def contextualize_def(%{name: "task"} = definition, config, authorized_tools) do
    profiles = ProfileRegistry.available(config.working_directory, authorized_tools)

    listing =
      Enum.map_join(profiles, "\n", fn profile ->
        suffix = if profile.mode == :write, do: " (writes in an isolated git worktree)", else: ""
        "- #{profile.name}: #{profile.description}#{suffix}"
      end)

    %{
      definition
      | description: definition.description <> "\n\nsubagent_type values:\n" <> listing
    }
  end

  def contextualize_def(definition, _config, _authorized_tools), do: definition
end
