defmodule Handbean.Tool.Builtin.Schedule do
  @moduledoc """
  Create and inspect schedules bound to the current conversation.

  Identity comes from the run context. A scheduled run, a delegated run, and a
  thread handoff cannot change a schedule.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Agent.{Channel, Message}
  alias Handbean.Schedule.{Rule, Store}

  @actions ~w(list get history create update pause resume delete run_now)
  @write_actions ~w(create update pause resume delete run_now)
  @allowed ~w(action id name instruction rule time_zone model reasoning_level)

  @impl true
  def name, do: "schedule"

  @impl true
  def description do
    """
    Manage schedules on the current conversation. The user says when and what in ordinary language. Turn that into a rule. There is no default frequency. Do not ask them to fill weekday numbers, cron, or a form.

    create and update need an explicit rule, the saved instruction, and an IANA time zone. Use the conversation time zone when they did not name one. Weekdays are 1=Monday through 7=Sunday. weekly is {kind, weekdays, times}. interval is {kind, every_minutes} with every_minutes >= 1 and keeps repeating. A single future check is once: {kind, in_minutes} or {kind, at} as a local YYYY-MM-DDTHH:MM. once runs one time and then stops. Do not store a one-shot check as interval. Put the concrete target in the instruction. Saving does not run the task. run_now does not move the next planned time.

    After create or update succeeds, reply in this chat in plain language: time zone, frequency, clock time, that each run is delivered in this chat, and the next local time from next_runs. Say they can change the frequency, time, or language by telling you. Do not dump the raw rule.

    A scheduled run cannot create, update, pause, resume, or delete a schedule.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: %{
        action: %{type: "string", enum: @actions},
        id: %{type: "string"},
        name: %{type: "string"},
        instruction: %{type: "string"},
        rule: %{
          type: "object",
          description:
            "weekly: {kind, weekdays, times}. interval: {kind, every_minutes} with every_minutes >= 1. once: {kind, in_minutes} or {kind, at} as local YYYY-MM-DDTHH:MM. once does not repeat."
        },
        time_zone: %{
          type: "string",
          description: "IANA time zone. Required when context has none."
        },
        model: %{
          type: "string",
          description: "Composite model id. Defaults to the current run model."
        },
        reasoning_level: %{type: "string"}
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @doc "Freeze one-shot rules in the latest assistant tool call before approval or execution."
  def freeze_messages(messages, context, now \\ Handbean.Schedule.now()) when is_list(messages) do
    zone = context_zone(context)

    {reversed, _done} =
      Enum.reduce(Enum.reverse(messages), {[], false}, fn message, {acc, done} ->
        freeze_message(message, zone, now, acc, done)
      end)

    reversed
  end

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    result =
      with :ok <- reject_unknown(input),
           {:ok, action} <- action(input),
           :ok <- write_allowed?(action, context),
           {:ok, conversation_id, workspace_id} <- identity(context) do
        perform(action, input, context, conversation_id, workspace_id)
      else
        {:error, reason} -> {:error, to_string(reason)}
      end

    case result do
      {:error, reason} when is_atom(reason) -> {:error, Atom.to_string(reason)}
      other -> other
    end
  end

  def execute(_, _), do: {:error, "invalid schedule input"}

  defp perform("list", _input, _context, conversation_id, _workspace_id) do
    rows =
      conversation_id
      |> Store.list_for_conversation()
      |> Enum.map(&summary/1)

    {:ok, Jason.encode!(rows)}
  end

  defp perform("get", input, _context, conversation_id, _workspace_id) do
    with {:ok, entry} <- fetch(conversation_id, input) do
      {:ok, Jason.encode!(summary(entry))}
    end
  end

  defp perform("history", input, _context, conversation_id, _workspace_id) do
    with {:ok, entry} <- fetch(conversation_id, input) do
      rows = entry.id |> Store.recent_runs(20) |> Enum.map(&run_summary/1)
      {:ok, Jason.encode!(rows)}
    end
  end

  defp perform("create", input, context, conversation_id, workspace_id) do
    with {:ok, zone} <- zone(input, context),
         {:ok, model} <- model(input, context),
         {:ok, rule} <- canonicalize(field(input, "rule"), zone) do
      attrs = %{
        workspace_id: workspace_id,
        conversation_id: conversation_id,
        name: field(input, "name") || "定时任务",
        instruction: field(input, "instruction"),
        rule: rule,
        time_zone: zone,
        model: model,
        reasoning_level: field(input, "reasoning_level"),
        created_by: "agent"
      }

      case Store.create(attrs) do
        {:ok, entry} -> {:ok, Jason.encode!(summary(entry))}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp perform("update", input, context, conversation_id, _workspace_id) do
    with {:ok, entry} <- fetch(conversation_id, input),
         {:ok, attrs} <- update_attrs(input, context, entry) do
      case Store.update(entry, attrs) do
        {:ok, updated} -> {:ok, Jason.encode!(summary(updated))}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp perform(action, input, _context, conversation_id, _workspace_id)
       when action in ["pause", "resume", "delete", "run_now"] do
    with {:ok, entry} <- fetch(conversation_id, input) do
      case action do
        "pause" -> finish(Store.pause(entry))
        "resume" -> finish(Store.resume(entry))
        "delete" -> finish_delete(Store.delete(entry))
        "run_now" -> run_now(entry)
      end
    end
  end

  defp perform(_action, _input, _context, _conversation_id, _workspace_id),
    do: {:error, "unknown schedule action"}

  defp run_now(entry) do
    case Store.run_now(entry) do
      {:ok, claim} ->
        Handbean.Schedule.Dispatch.run(claim)
        {:ok, "run requested"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp finish({:ok, entry}), do: {:ok, Jason.encode!(summary(entry))}
  defp finish({:error, reason}), do: {:error, inspect(reason)}
  defp finish_delete(:ok), do: {:ok, "deleted"}
  defp finish_delete({:error, reason}), do: {:error, inspect(reason)}

  defp update_attrs(input, context, entry) do
    zone = field(input, "time_zone") || entry.time_zone

    with :ok <- if(Rule.valid_zone?(zone), do: :ok, else: {:error, :invalid_time_zone}),
         {:ok, rule} <- canonicalize(field(input, "rule") || entry.rule, zone) do
      attrs = %{
        name: field(input, "name") || entry.name,
        instruction: field(input, "instruction") || entry.instruction,
        rule: rule,
        time_zone: zone,
        reasoning_level: field(input, "reasoning_level") || entry.reasoning_level
      }

      attrs =
        case model(input, context) do
          {:ok, model} -> Map.put(attrs, :model, model)
          _ -> Map.put(attrs, :model, entry.model)
        end

      {:ok, attrs}
    end
  end

  defp fetch(conversation_id, input) do
    case field(input, "id") do
      id when is_binary(id) and id != "" -> Store.get_for_conversation(conversation_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp canonicalize(rule, zone) do
    if once_input?(rule) do
      case Rule.prepare_once(rule, zone, Handbean.Schedule.now()) do
        {:ok, canonical} -> {:ok, Rule.dump(canonical)}
        error -> error
      end
    else
      {:ok, rule}
    end
  end

  defp once_input?(rule) when is_map(rule) do
    Handbean.Utils.SafeMap.get_any(rule, ["kind", :kind]) in ["once", :once]
  end

  defp once_input?(_rule), do: false

  defp context_zone(context) when is_map(context), do: context[:user_time_zone]
  defp context_zone(_context), do: nil

  defp freeze_message(
         %Message{role: :assistant, content: content} = message,
         zone,
         now,
         acc,
         false
       )
       when is_list(content) do
    if Message.tool_calls(message) == [] do
      {[message | acc], false}
    else
      {[%{message | content: Enum.map(content, &freeze_block(&1, zone, now))} | acc], true}
    end
  end

  defp freeze_message(message, _zone, _now, acc, done), do: {[message | acc], done}

  defp freeze_block(block, zone, now) when is_map(block) do
    type = block_value(block, "type")
    name = block_value(block, "name")
    input = block_value(block, "input") || %{}
    action = field(input, "action")
    rule = field(input, "rule")

    if type == "tool_use" and name == "schedule" and action in ["create", "update"] and
         once_input?(rule) do
      rule_zone = field(input, "time_zone") || zone

      case Rule.prepare_once(rule, rule_zone, now) do
        {:ok, canonical} ->
          put_block(block, "input", Map.put(input, "rule", Rule.dump(canonical)))

        _ ->
          block
      end
    else
      block
    end
  end

  defp freeze_block(block, _zone, _now), do: block

  defp block_value(block, key) do
    Map.get(block, key) || Map.get(block, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(block, key)
  end

  defp put_block(block, key, value) do
    cond do
      Map.has_key?(block, key) -> Map.put(block, key, value)
      Map.has_key?(block, String.to_atom(key)) -> Map.put(block, String.to_atom(key), value)
      true -> Map.put(block, key, value)
    end
  end

  defp zone(input, context) do
    zone = field(input, "time_zone") || context[:user_time_zone]

    if Rule.valid_zone?(zone), do: {:ok, zone}, else: {:error, :time_zone_required}
  end

  defp model(input, context) do
    explicit = field(input, "model")

    cond do
      is_binary(explicit) and explicit != "" ->
        {:ok, explicit}

      true ->
        opts = context[:thread_run_opts] || []
        model = opts[:model]

        provider =
          get_in(opts, [:provider_config, :provider_key]) ||
            get_in(opts, [:provider_config, :provider])

        if is_binary(provider) and is_binary(model) and model != "" do
          {:ok, "#{provider}/#{model}"}
        else
          {:error, :model_required}
        end
    end
  end

  defp identity(context) do
    conversation_id = context[:conversation_id]
    workspace_id = context[:workspace_id]

    if is_binary(conversation_id) and conversation_id != "" and is_binary(workspace_id) and
         workspace_id != "" do
      {:ok, conversation_id, workspace_id}
    else
      {:error, :schedule_requires_workspace_conversation}
    end
  end

  defp write_allowed?(action, context) when action in @write_actions do
    source = context[:source] || config_source(context)
    delegated? = get_in(context, [:delegation_config, Access.key(:delegated?)]) == true
    handoff = context[:thread_handoff_id]

    if Channel.interactive?(source) and not delegated? and is_nil(handoff) do
      :ok
    else
      {:error, :schedule_changes_require_user_turn}
    end
  end

  defp write_allowed?(_action, _context), do: :ok

  defp config_source(context) do
    case context[:delegation_config] do
      %{source: source} -> source
      _ -> nil
    end
  end

  defp reject_unknown(input) do
    extra =
      input
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @allowed))

    if extra == [] do
      :ok
    else
      {:error, "unexpected fields: #{Enum.join(extra, ", ")}"}
    end
  end

  defp action(input) do
    action = field(input, "action")

    if action in @actions do
      {:ok, action}
    else
      {:error, :unknown_action}
    end
  end

  defp field(input, key) do
    Handbean.Utils.SafeMap.get(input, key)
  end

  defp summary(entry) do
    %{
      id: entry.id,
      name: entry.name,
      instruction: entry.instruction,
      rule: entry.rule,
      description: Rule.describe(entry.rule),
      time_zone: entry.time_zone,
      model: entry.model,
      reasoning_level: entry.reasoning_level,
      status: entry.status,
      next_run_at: iso(entry.next_run_at),
      next_runs: upcoming_local(entry),
      version: entry.version,
      created_by: entry.created_by
    }
  end

  defp run_summary(run) do
    %{
      id: run.id,
      slot_at: iso(run.slot_at),
      kind: run.kind,
      status: run.status,
      reason: run.reason,
      run_id: run.run_id
    }
  end

  defp upcoming_local(entry) do
    case Rule.upcoming(entry.rule, entry.time_zone, DateTime.utc_now(), 3) do
      {:ok, times} -> Enum.map(times, &Rule.format_local(&1, entry.time_zone))
      _ -> []
    end
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil
end
