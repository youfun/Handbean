defmodule Handbean.Memory.Reflector do
  @moduledoc """
  Produces one bounded, auditable memory candidate from a persisted compaction
  checkpoint.

  Automatic reflection is opt-in. `maybe_trigger/3` starts work only when the
  run options explicitly enable the reflector. `trigger/1` through `trigger/3`
  are manual asynchronous entry points, while `run/2` and `run/3` execute
  synchronously for callers that need the result.

  Reflection is workspace-only. The model receives the persisted checkpoint
  summary and a bounded projection of active memories in that workspace; raw
  conversation entries are never included.
  """

  require Logger

  alias Handbean.Agent.{CompactionCheckpoint, Config, Message, ModelConfig, Reasoning}
  alias Handbean.ConversationTranscriptStore
  alias Handbean.Memory.{MemoryStore, Policy}
  alias Handbean.Repo
  alias Handbean.Settings.ModelAISettings

  @audit_content_type "memory_reflection"
  @audit_id_prefix "memory-reflection-"
  @candidate_ttl_hours 168
  @max_summary_chars 12_000
  @max_memories 40
  @max_memory_chars 600
  @max_memories_chars 12_000
  @max_response_bytes 4_096
  @default_timeout_ms 30_000
  @max_timeout_ms 60_000
  @max_output_tokens 512
  @kinds ~w(fact pattern preference rule context)

  @system_prompt """
  You are Handbean's memory reflector. Decide whether the supplied compaction
  summary contains exactly one durable, non-obvious, reusable workspace memory
  that is not already represented by the active memories.

  Return exactly one JSON object and nothing else. Do not use Markdown fences,
  prose outside the JSON, or tools.

  Candidate schema (keys must be exact):
  {"type":"candidate","kind":"fact|pattern|preference|rule|context","content":"..."}

  Ignore schema (keys must be exact):
  {"type":"ignore","reason":"..."}

  Ignore secrets, credentials, personal data, transient output, generic task
  summaries, and facts that are obvious from reading the repository.
  """

  @type checkpoint_ref :: map() | String.t() | :latest
  @type trigger_checkpoint :: String.t() | :latest
  @type result ::
          {:ok, {:candidate, Handbean.Memory.Engram.t()}}
          | {:ok, {:duplicate, Handbean.Memory.Engram.t()}}
          | {:ok, {:rejected, String.t()}}
          | {:ok, :ignored | :already_reflected}
          | {:error, term()}

  @doc """
  Start automatic reflection when explicitly enabled.

  The Runner passes the persisted checkpoint returned by
  `CompactionCheckpoint.persist/3`. This function never raises into the main
  turn; startup errors are logged and returned.
  """
  @spec maybe_trigger(String.t(), map(), keyword()) ::
          {:ok, pid()} | :disabled | {:error, term()}
  def maybe_trigger(conversation_id, checkpoint, opts \\ [])
      when is_binary(conversation_id) and is_map(checkpoint) and is_list(opts) do
    if auto_enabled?(opts) do
      start_async(conversation_id, checkpoint, opts)
    else
      :disabled
    end
  rescue
    error ->
      log_async_failure(conversation_id, error, __STACKTRACE__)
      {:error, error}
  catch
    kind, reason ->
      log_async_failure(conversation_id, {kind, reason}, __STACKTRACE__)
      {:error, {kind, reason}}
  end

  @doc "Start a manual asynchronous reflection for the latest or an explicit checkpoint."
  @spec trigger(String.t(), trigger_checkpoint(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def trigger(conversation_id, checkpoint_id \\ :latest, opts \\ [])
      when is_binary(conversation_id) and
             (checkpoint_id == :latest or is_binary(checkpoint_id)) and is_list(opts) do
    start_async(conversation_id, checkpoint_id, opts)
  end

  @doc "Synchronously reflect the latest persisted checkpoint."
  @spec run(String.t(), keyword()) :: result()
  def run(conversation_id, opts \\ [])
      when is_binary(conversation_id) and is_list(opts) do
    run(conversation_id, :latest, opts)
  end

  @doc "Synchronously reflect an explicit persisted checkpoint."
  @spec run(String.t(), checkpoint_ref(), keyword()) :: result()
  def run(conversation_id, checkpoint_ref, opts)
      when is_binary(conversation_id) and is_list(opts) do
    with {:ok, workspace} <- workspace_context(conversation_id, opts),
         opts <- hydrate_runtime_opts(workspace.workspace_path, opts),
         {:ok, entries} <- ConversationTranscriptStore.list(conversation_id, opts),
         {:ok, checkpoint} <- load_checkpoint(entries, checkpoint_ref) do
      reflect_serialized(conversation_id, checkpoint, workspace, opts)
    end
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_async(conversation_id, checkpoint_ref, opts) do
    case Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
           case run(conversation_id, checkpoint_ref, opts) do
             {:error, reason} ->
               Logger.warning(fn ->
                 "[Reflector] reflection failed conversation_id=#{conversation_id} " <>
                   "reason=#{inspect(reason)}"
               end)

             _result ->
               :ok
           end
         end) do
      {:ok, _pid} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning(fn ->
          "[Reflector] could not start conversation_id=#{conversation_id} " <>
            "reason=#{inspect(reason)}"
        end)

        error
    end
  rescue
    error ->
      log_async_failure(conversation_id, error, __STACKTRACE__)
      {:error, error}
  catch
    kind, reason ->
      log_async_failure(conversation_id, {kind, reason}, __STACKTRACE__)
      {:error, {kind, reason}}
  end

  defp reflect_serialized(conversation_id, checkpoint, workspace, opts) do
    lock = {{__MODULE__, conversation_id, checkpoint["id"]}, self()}

    case :global.trans(
           lock,
           fn -> reflect_locked(conversation_id, checkpoint["id"], workspace, opts) end,
           [Node.self()],
           :infinity
         ) do
      :aborted -> {:error, :lock_aborted}
      {:error, :aborted} -> {:error, :lock_aborted}
      result -> result
    end
  end

  defp reflect_locked(conversation_id, checkpoint_id, workspace, opts) do
    with {:ok, entries} <- ConversationTranscriptStore.list(conversation_id, opts),
         {:ok, checkpoint} <- load_checkpoint(entries, checkpoint_id),
         false <- audit_present?(entries, checkpoint["id"]),
         memories <- active_memories(workspace.workspace_id),
         prompt <- build_prompt(checkpoint["summary"], memories),
         {:ok, provider, provider_config} <- provider_request(workspace, opts),
         {:ok, response} <- complete_within(provider, prompt, provider_config, opts),
         {:ok, decision} <- parse_response(response) do
      persist_decision(conversation_id, checkpoint, decision, workspace.workspace_id, opts)
    else
      true -> {:ok, :already_reflected}
      {:error, _reason} = error -> error
    end
  end

  defp workspace_context(conversation_id, opts) do
    with {:ok, metadata} <- Handbean.ConversationStore.get_metadata(conversation_id),
         "workspace" <- metadata["scope"],
         workspace_id when is_binary(workspace_id) and workspace_id != "" <-
           metadata["workspace_id"],
         :ok <- match_requested_workspace(workspace_id, Keyword.get(opts, :workspace_id)) do
      {:ok,
       %{
         workspace_id: workspace_id,
         workspace_path:
           first_present([
             Keyword.get(opts, :workspace_path),
             Keyword.get(opts, :working_directory),
             metadata["checkout_path"]
           ])
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :workspace_required}
    end
  end

  defp match_requested_workspace(_persisted, nil), do: :ok
  defp match_requested_workspace(_persisted, ""), do: {:error, :invalid_scope}
  defp match_requested_workspace(workspace_id, workspace_id), do: :ok
  defp match_requested_workspace(_persisted, _requested), do: {:error, :scope_mismatch}

  defp hydrate_runtime_opts(workspace_path, opts)
       when is_binary(workspace_path) and workspace_path != "" do
    if runtime_provider_supplied?(opts) do
      opts
    else
      defaults =
        workspace_path
        |> Handbean.Settings.effective_model_ai()
        |> ModelAISettings.to_runtime_opts()

      Keyword.merge(defaults, opts, fn
        :om, default, explicit when is_map(default) and is_map(explicit) ->
          Map.merge(default, explicit)

        _key, _default, explicit ->
          explicit
      end)
    end
  end

  defp hydrate_runtime_opts(_workspace_path, opts), do: opts

  defp runtime_provider_supplied?(opts) do
    provider = Keyword.get(opts, :provider)
    provider_config = Keyword.get(opts, :provider_config)

    (is_atom(provider) and not is_nil(provider)) or
      (is_map(provider_config) and map_size(provider_config) > 0)
  end

  defp load_checkpoint(entries, :latest) do
    entries
    |> Enum.reverse()
    |> Enum.find(&persisted_checkpoint?/1)
    |> checkpoint_result()
  end

  defp load_checkpoint(entries, %{} = checkpoint) do
    load_checkpoint(entries, checkpoint["id"] || checkpoint[:id])
  end

  defp load_checkpoint(entries, checkpoint_id)
       when is_binary(checkpoint_id) and checkpoint_id != "" do
    entries
    |> Enum.find(&(&1["id"] == checkpoint_id and persisted_checkpoint?(&1)))
    |> checkpoint_result()
  end

  defp load_checkpoint(_entries, _checkpoint_ref), do: {:error, :checkpoint_not_found}

  defp persisted_checkpoint?(entry) do
    CompactionCheckpoint.checkpoint?(entry) and
      is_binary(entry["id"]) and entry["id"] != "" and
      is_binary(entry["summary"]) and String.trim(entry["summary"]) != ""
  end

  defp checkpoint_result(nil), do: {:error, :checkpoint_not_found}
  defp checkpoint_result(checkpoint), do: {:ok, checkpoint}

  defp audit_present?(entries, checkpoint_id) do
    audit_id = audit_id(checkpoint_id)

    Enum.any?(entries, fn entry ->
      entry["id"] == audit_id and entry["content_type"] == @audit_content_type
    end)
  end

  defp active_memories(workspace_id) do
    [
      workspace_id: workspace_id,
      scope: :workspace,
      memory_scope: :workspace,
      privacy_mode: :local_only,
      lifecycle: :active,
      preload_synapses: false
    ]
    |> MemoryStore.list_engrams()
    |> Enum.take(@max_memories)
    |> Enum.reduce_while({[], 0}, fn engram, {acc, used} ->
      content = truncate(engram.content, @max_memory_chars)
      size = String.length(content)

      if used + size > @max_memories_chars do
        {:halt, {acc, used}}
      else
        memory = %{
          "id" => engram.id,
          "kind" => Atom.to_string(engram.kind),
          "content" => content
        }

        {:cont, {[memory | acc], used + size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp build_prompt(summary, memories) do
    input = %{
      "checkpoint_summary" => truncate(summary, @max_summary_chars),
      "active_memories" => memories
    }

    "Reflect on this bounded workspace input:\n" <> Handbean.JSON.encode!(input)
  end

  defp provider_request(workspace, opts) do
    om = map_option(opts, :om)
    om_model = map_value(om, :model)
    model_ref = om_model || Keyword.get(opts, :model)
    reasoning = map_value(om, :reasoning) || Keyword.get(opts, :reasoning_level)
    supplied_config = opts |> Keyword.get(:provider_config, %{}) |> ensure_map()

    with {:ok, config, model_entry} <-
           resolve_provider_config(
             model_ref,
             workspace.workspace_path,
             supplied_config,
             is_binary(om_model) and om_model != ""
           ),
         provider <- resolve_provider(opts, om, config),
         true <- is_atom(provider) do
      config =
        config
        |> isolate_provider_config()
        |> apply_reasoning(model_entry, reasoning)

      {:ok, provider, config}
    else
      false -> {:error, :provider_not_configured}
      {:error, _reason} = error -> error
    end
  end

  defp provider_config_resolution(model_ref, supplied_config, dedicated_model?)
       when map_size(supplied_config) > 0 and not dedicated_model? do
    {:ok, supplied_config, model_entry(supplied_config, model_ref)}
  end

  defp provider_config_resolution(model_ref, supplied_config, true)
       when map_size(supplied_config) > 0 do
    if supplied_model_matches?(supplied_config, model_ref) do
      {:ok, supplied_config, model_entry(supplied_config, model_ref)}
    else
      {:resolve, model_ref}
    end
  end

  defp provider_config_resolution(model_ref, _supplied_config, _dedicated_model?)
       when is_binary(model_ref) and model_ref != "" do
    {:resolve, model_ref}
  end

  defp provider_config_resolution(_model_ref, _supplied_config, _dedicated_model?),
    do: {:error, :model_not_configured}

  defp resolve_provider_config(model_ref, workspace_path, supplied_config, dedicated_model?) do
    case provider_config_resolution(model_ref, supplied_config, dedicated_model?) do
      {:resolve, composite_id}
      when is_binary(workspace_path) and workspace_path != "" and
             is_binary(composite_id) and composite_id != "" ->
        case ModelConfig.resolve_model_for_workspace(workspace_path, composite_id) do
          {:ok, config, actual_model} ->
            {:ok, Map.put(config, :model, actual_model),
             configured_model_entry(workspace_path, composite_id)}

          {:error, reason} ->
            {:error, {:model_config, reason}}
        end

      {:resolve, _model_ref} ->
        {:error, :workspace_path_required}

      result ->
        result
    end
  end

  defp supplied_model_matches?(config, model_ref) do
    actual_model = Map.get(config, :model) || Map.get(config, "model")
    provider_key = Map.get(config, :provider_key) || Map.get(config, "provider_key")

    model_ref == actual_model or
      (is_binary(provider_key) and provider_key != "" and
         model_ref == "#{provider_key}/#{actual_model}")
  end

  defp configured_model_entry(workspace_path, model_ref) do
    workspace_path
    |> ModelConfig.available_models_for_workspace()
    |> Enum.find(%{}, &(&1.id == model_ref))
  end

  defp model_entry(config, model_ref) do
    config
    |> Map.get(:model_meta, Map.get(config, "model_meta", %{}))
    |> ensure_map()
    |> Map.put_new("id", Map.get(config, :model) || model_ref || "")
    |> Map.put_new("provider", Map.get(config, :provider) || Map.get(config, "provider"))
    |> Map.put_new("api", Map.get(config, :api) || Map.get(config, "api"))
  end

  defp resolve_provider(opts, om, config) do
    Keyword.get(opts, :provider) ||
      atom_value(config, :provider_module) ||
      atom_value(om, :provider) ||
      Config.resolve_provider_from_api(
        Map.get(config, :api) || Map.get(config, "api"),
        Map.get(config, :model) || Map.get(config, "model"),
        Map.get(config, :provider) || Map.get(config, "provider")
      )
  end

  defp isolate_provider_config(config) do
    config
    |> Map.drop([
      :provider_state,
      "provider_state",
      :previous_response_id,
      "previous_response_id",
      :use_previous_response_id,
      "use_previous_response_id",
      :conversation_id,
      "conversation_id",
      :session_id,
      "session_id",
      :run_id,
      "run_id",
      :cache_fork,
      "cache_fork",
      :cache_fork_suffix,
      "cache_fork_suffix",
      :extended_thinking,
      "extended_thinking",
      :thinking,
      "thinking",
      :output_config,
      "output_config",
      :reasoning,
      "reasoning",
      :reasoning_effort,
      "reasoning_effort",
      :include,
      "include",
      :built_in_tools,
      "built_in_tools",
      :web_search,
      "web_search",
      :x_search,
      "x_search",
      :tool_choice,
      "tool_choice",
      :parallel_tool_calls,
      "parallel_tool_calls",
      :stream,
      "stream",
      :on_chunk,
      "on_chunk"
    ])
    |> Map.put(:system_prompt, @system_prompt)
    |> Map.put(:stream, false)
    |> Map.put(:use_previous_response_id, false)
    |> Map.put(:max_tokens, @max_output_tokens)
    |> Map.put(:max_output_tokens, @max_output_tokens)
    |> Map.put(:temperature, 0)
    |> Map.put(:max_retries, 0)
    |> Map.put(:retry_count, 0)
  end

  defp apply_reasoning(config, model_entry, reasoning) when is_map(model_entry) do
    selected =
      case reasoning do
        value when is_binary(value) and value != "" -> value
        _ -> Reasoning.default_level(model_entry)
      end

    Reasoning.apply_provider_options(config, model_entry, selected)
  end

  defp complete_within(provider, prompt, config, opts) do
    timeout = reflector_timeout(opts)

    task =
      Task.async(fn ->
        try do
          provider.complete([Message.user(prompt)], [], config)
        rescue
          error -> {:error, {:provider_exception, error}}
        catch
          kind, reason -> {:error, {:provider_throw, kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> normalize_provider_result(result)
      {:exit, reason} -> {:error, {:provider_exit, reason}}
      nil -> {:error, :provider_timeout}
    end
  end

  defp normalize_provider_result({:ok, response}) when is_map(response), do: {:ok, response}
  defp normalize_provider_result({:error, reason}), do: {:error, {:provider, reason}}
  defp normalize_provider_result(other), do: {:error, {:invalid_provider_response, other}}

  defp parse_response(%{stop_reason: :end_turn, messages: [%Message{role: :assistant} = message]}) do
    with :ok <- reject_tool_calls(message),
         {:ok, text} <- strict_text(message),
         true <- byte_size(text) <= @max_response_bytes,
         {:ok, decoded} <- decode_json(text),
         {:ok, decision} <- validate_decision(decoded) do
      {:ok, decision}
    else
      false -> {:error, :reflection_response_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp parse_response(%{stop_reason: :tool_use}), do: {:error, :reflection_tool_call}
  defp parse_response(_response), do: {:error, :invalid_reflection_response}

  defp reject_tool_calls(%Message{} = message) do
    if Message.tool_calls(message) == [] and empty_tool_calls_field?(message.tool_calls) do
      :ok
    else
      {:error, :reflection_tool_call}
    end
  end

  defp empty_tool_calls_field?(nil), do: true
  defp empty_tool_calls_field?([]), do: true
  defp empty_tool_calls_field?(_calls), do: false

  defp strict_text(%Message{content: content}) when is_binary(content) do
    case String.trim(content) do
      "" -> {:error, :empty_reflection_response}
      text -> {:ok, text}
    end
  end

  defp strict_text(%Message{content: blocks}) when is_list(blocks) do
    {text_blocks, metadata_blocks} =
      Enum.split_with(blocks, fn
        block when is_map(block) -> block_type(block) == "text"
        _other -> false
      end)

    with true <- Enum.all?(metadata_blocks, &reasoning_block?/1),
         [text_block] <- text_blocks,
         text when is_binary(text) <- Map.get(text_block, :text) || Map.get(text_block, "text"),
         text when text != "" <- String.trim(text) do
      {:ok, text}
    else
      _other -> {:error, :invalid_reflection_response}
    end
  end

  defp strict_text(_message), do: {:error, :invalid_reflection_response}

  defp reasoning_block?(block) when is_map(block),
    do: block_type(block) in ["responses_reasoning", "thinking"]

  defp reasoning_block?(_block), do: false

  defp block_type(block), do: to_string(Map.get(block, :type) || Map.get(block, "type") || "")

  defp decode_json(text) do
    case Handbean.JSON.decode(text) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :malformed_reflection_json}
    end
  end

  defp validate_decision(
         %{
           "type" => "candidate",
           "kind" => kind,
           "content" => content
         } = decoded
       )
       when map_size(decoded) == 3 and kind in @kinds and is_binary(content) do
    if String.trim(content) == "" do
      {:error, :invalid_reflection_candidate}
    else
      {:ok, {:candidate, kind_atom(kind), content}}
    end
  end

  defp validate_decision(%{"type" => "ignore", "reason" => reason} = decoded)
       when map_size(decoded) == 2 and is_binary(reason) do
    if String.trim(reason) == "",
      do: {:error, :invalid_reflection_ignore},
      else: {:ok, {:ignore, truncate(String.trim(reason), 500)}}
  end

  defp validate_decision(_decoded), do: {:error, :invalid_reflection_schema}

  defp kind_atom("fact"), do: :fact
  defp kind_atom("pattern"), do: :pattern
  defp kind_atom("preference"), do: :preference
  defp kind_atom("rule"), do: :rule
  defp kind_atom("context"), do: :context

  defp persist_decision(conversation_id, checkpoint, decision, workspace_id, opts) do
    transaction(fn ->
      case decision do
        {:ignore, reason} ->
          persist_audit(conversation_id, checkpoint, "ignore", %{reason: reason}, opts)
          {:ok, :ignored}

        {:candidate, kind, content} ->
          persist_candidate(conversation_id, checkpoint, kind, content, workspace_id, opts)
      end
    end)
  end

  defp persist_candidate(conversation_id, checkpoint, kind, content, workspace_id, opts) do
    case Policy.validate_candidate_memory(content) do
      {:error, reason} ->
        persist_audit(
          conversation_id,
          checkpoint,
          "policy_rejected",
          %{kind: kind, reason: reason},
          opts
        )

        {:ok, {:rejected, reason}}

      {:ok, validated} ->
        scope_opts = workspace_scope_opts(workspace_id)

        case MemoryStore.find_active_exact(validated, kind, scope_opts) do
          {:ok, engram} ->
            persist_audit(
              conversation_id,
              checkpoint,
              "duplicate",
              %{kind: kind, engram_id: engram.id},
              opts
            )

            {:ok, {:duplicate, engram}}

          :none ->
            case MemoryStore.learn(
                   validated,
                   kind,
                   scope_opts ++
                     [
                       short_term: true,
                       ttl_hours: @candidate_ttl_hours,
                       metadata: %{
                         "source" => "reflector",
                         "conversation_id" => conversation_id,
                         "checkpoint_id" => checkpoint["id"]
                       }
                     ]
                 ) do
              {:ok, engram} ->
                persist_audit(
                  conversation_id,
                  checkpoint,
                  "candidate",
                  %{kind: kind, engram_id: engram.id},
                  opts
                )

                {:ok, {:candidate, engram}}

              {:error, reason} ->
                Repo.rollback({:memory_write, reason})
            end

          {:error, reason} ->
            Repo.rollback({:duplicate_check, reason})
        end
    end
  end

  defp persist_audit(conversation_id, checkpoint, outcome, attrs, opts) do
    entry =
      %{
        "id" => audit_id(checkpoint["id"]),
        "content_type" => @audit_content_type,
        "message_type" => "internal",
        "role" => "internal",
        "direction" => "internal",
        "checkpoint_id" => checkpoint["id"],
        "outcome" => outcome,
        "content" => audit_content(outcome, attrs)
      }
      |> Map.merge(stringify_audit_attrs(attrs))

    case ConversationTranscriptStore.append(conversation_id, entry, opts) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_write, reason})
    end
  end

  defp audit_content("candidate", _attrs), do: "Created a short-term memory candidate"
  defp audit_content("duplicate", _attrs), do: "Skipped a duplicate memory candidate"
  defp audit_content("policy_rejected", attrs), do: "Rejected memory candidate: #{attrs.reason}"
  defp audit_content("ignore", attrs), do: "No memory candidate: #{attrs.reason}"

  defp stringify_audit_attrs(attrs) do
    Map.new(attrs, fn
      {:kind, kind} when is_atom(kind) -> {"kind", Atom.to_string(kind)}
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
    end)
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, {:ok, _result} = result} -> result
      {:ok, {:error, _reason} = error} -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_scope_opts(workspace_id) do
    [
      memory_scope: :workspace,
      scope: :workspace,
      workspace_id: workspace_id,
      privacy_mode: :local_only
    ]
  end

  defp auto_enabled?(opts) do
    Keyword.get(opts, :builtin_memory_enabled) == true and
      opts
      |> map_option(:om)
      |> map_value(:reflector_enabled)
      |> Kernel.==(true)
  end

  defp reflector_timeout(opts) do
    case Keyword.get(opts, :reflector_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, @max_timeout_ms)
      _ -> @default_timeout_ms
    end
  end

  defp audit_id(checkpoint_id), do: @audit_id_prefix <> checkpoint_id

  defp map_option(opts, key) do
    opts |> Keyword.get(key, %{}) |> ensure_map()
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil

  defp atom_value(map, key) do
    case map_value(map, key) do
      value when is_atom(value) -> value
      _ -> nil
    end
  end

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_value), do: %{}

  defp first_present(values) do
    Enum.find(values, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp truncate(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp truncate(_value, _limit), do: ""

  defp log_async_failure(conversation_id, reason, stacktrace) do
    Logger.warning(fn ->
      "[Reflector] async startup failed conversation_id=#{conversation_id} " <>
        "reason=#{Exception.format(:error, reason, stacktrace)}"
    end)
  end
end
