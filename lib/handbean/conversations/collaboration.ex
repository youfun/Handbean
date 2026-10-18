defmodule Handbean.Conversations.Collaboration do
  @moduledoc """
  Bounded asynchronous handoffs through Coordinator. Transcript entries are the
  durable outbox and UI projection source, not a second message store.

  A reservation is written before dispatch under a workspace lock. An uncertain
  dispatch is NEVER replayed automatically (at-most-once wakeup). The caller sees
  delivery_unknown and a human may inspect/intervene in the target conversation.
  """
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Conversations}

  # Inspection and handoff only. Mutating, shell, browser, extension, and
  # further-delegation tools stay off this list.
  @read_tools ~w(
    read file_search grep code_search web_fetch skill tool_search mem_recall
    list_models list_conversations find_conversation search_conversations read_conversation
    get_conversation_status get_conversation_trajectory reply_to_parent_conversation
    send_conversation_message
  )

  @purposes ~w(request progress result notification)
  @dispatch_run_opts ~w(workspace_path transcript_store)a

  def completed(id, result, opts) do
    status = if is_map(result), do: Map.get(result, :status, :error), else: :error
    ConversationStore.update_meta(id, last_run_result: to_string(status))
    report_terminal(id, status, opts)
    :ok
  end

  def read_tools, do: @read_tools

  def read_only?(context) when is_map(context) do
    case ConversationStore.get_metadata(context[:conversation_id]) do
      {:ok, %{"collaboration" => %{"read_only" => true}}} -> true
      _ -> context[:delegated_read_only] == true
    end
  end

  def read_only?(_context), do: false

  def tool_allowed?(name, context) do
    not read_only?(context) or name in @read_tools
  end

  def send_message(input, context) do
    input = normalize_optional_handoff(input)

    with :ok <-
           Conversations.validate(
             input,
             ~w(conversation message request_id deliver_as handoff_id purpose)
           ),
         {:ok, source} <- Conversations.identity(context),
         {:ok, target} <- Conversations.authorize(context, input["conversation"]) do
      locked(source, fn -> deliver(input, context, source, target, false) end)
    end
  end

  def reply(input, context) do
    input = normalize_optional_handoff(input)

    with :ok <- Conversations.validate(input, ~w(message request_id handoff_id purpose)),
         {:ok, source} <- Conversations.identity(context),
         parent when is_binary(parent) <- ConversationStore.parent_conversation_id(source),
         {:ok, target} <- Conversations.authorize(context, parent) do
      inherited_handoff =
        if context[:origin_conversation_id] == parent,
          do: context[:handoff_id]

      input =
        case input["handoff_id"] || inherited_handoff do
          handoff_id when is_binary(handoff_id) -> Map.put(input, "handoff_id", handoff_id)
          _ -> input
        end

      locked(source, fn -> deliver(input, context, source, target, true) end)
    else
      nil -> {:error, :no_parent}
      error -> error
    end
  end

  def create(input, context) do
    with :ok <-
           Conversations.validate(input, ~w(title message request_id model mode)),
         {:ok, source} <- Conversations.identity(context),
         {:ok, title} <- Conversations.text(input, "title", nil, 200),
         {:ok, key} <- Conversations.text(input, "request_id", nil, 128),
         {:ok, _} <- Conversations.text(input, "message", nil, 8000),
         {:ok, read_only} <- access(input),
         {:ok, selection} <- model_selection(input),
         true <- is_nil(source["collaboration"]),
         {:ok, pinned} <- resolve_selection(selection, context) do
      locked(source, fn ->
        id = "delegated-" <> digest({source["id"], key})

        with {:ok, target} <-
               child(
                 source,
                 context,
                 id,
                 title,
                 read_only,
                 pinned
               ),
             {:ok, receipt} <- deliver(input, context, source, target, false) do
          {:ok,
           Map.merge(receipt, %{
             model: selection || "current",
             mode: if(read_only, do: "read_only", else: "write")
           })}
        end
      end)
    else
      false -> {:error, :delegation_not_permitted}
      error -> error
    end
  end

  defp access(input) do
    case Map.get(input, "mode", "read_only") do
      "read_only" -> {:ok, true}
      "write" -> {:ok, false}
      _ -> {:error, :invalid_input}
    end
  end

  defp model_selection(input) do
    model = Map.get(input, "model")

    cond do
      model in [nil, "", "current"] -> {:ok, nil}
      catalog_ref?(model) -> {:ok, model}
      true -> {:error, :invalid_input}
    end
  end

  defp catalog_ref?(value) do
    is_binary(value) and String.valid?(value) and String.length(value) <= 256 and
      String.contains?(value, "/") and not String.contains?(value, ["\n", "\r", "\0"])
  end

  defp resolve_selection(nil, _context), do: {:ok, nil}

  defp resolve_selection(model_ref, context) do
    path = workspace_path(context)

    if is_binary(path) and path != "" do
      model =
        Enum.find(
          Handbean.Agent.ModelConfig.available_models_for_workspace(path),
          &(&1.id == model_ref)
        )

      case model && Handbean.Agent.ModelConfig.resolve_model_for_workspace(path, model_ref) do
        {:ok, _config, model_id} ->
          {:ok, %{"provider" => model.provider_id, "model" => model_id}}

        _ ->
          {:error, "Model #{model_ref} is not available. Call list_models to find a model id."}
      end
    else
      {:error, :missing_runtime_configuration}
    end
  end

  defp workspace_path(context) do
    opts = context[:conversation_run_opts] || []
    Keyword.get(opts, :workspace_path) || Keyword.get(opts, :working_directory)
  end

  defp child(source, context, id, title, read_only, pinned) do
    spec =
      %{"read_only" => read_only}
      |> maybe_put("provider", pinned && pinned["provider"])
      |> maybe_put("model", pinned && pinned["model"])

    selected_model = child_selected_model(source, pinned, context)

    case ConversationStore.get_metadata(id) do
      {:ok, target} ->
        if child_matches?(target, source["id"], spec),
          do: {:ok, target},
          else: {:error, :idempotency_conflict}

      _ ->
        ConversationStore.create(source["workspace_id"],
          id: id,
          title: title,
          parent_conversation_id: source["id"],
          parent_run_id: context[:run_id],
          parent_tool_call_id: context[:tool_call_id],
          checkout_path: source["checkout_path"],
          selected_model: selected_model,
          collaboration: spec
        )
    end
  end

  defp child_selected_model(_source, %{"provider" => provider, "model" => model}, _context)
       when is_binary(provider) and is_binary(model),
       do: "#{provider}/#{model}"

  defp child_selected_model(source, _pinned, context) do
    source["selected_model"] || inherited_model_ref(context[:conversation_run_opts])
  end

  defp inherited_model_ref(opts) when is_list(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) -> if String.contains?(model, "/"), do: model
      _ -> nil
    end
  end

  defp inherited_model_ref(_opts), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_optional_handoff(%{"handoff_id" => handoff_id} = input)
       when is_binary(handoff_id) do
    if String.trim(handoff_id) == "", do: Map.delete(input, "handoff_id"), else: input
  end

  defp normalize_optional_handoff(input), do: input

  defp child_matches?(target, parent_id, spec) do
    collab = target["collaboration"] || %{}

    ConversationStore.parent_conversation_id(target) == parent_id and
      Enum.all?(~w(read_only provider model), fn key ->
        Map.get(collab, key) == Map.get(spec, key)
      end)
  end

  defp deliver(input, context, source, target, important, trusted \\ %{}) do
    with {:ok, source} <- Conversations.authorize(context, source["id"]),
         {:ok, target} <- Conversations.authorize(context, target["id"]),
         {:ok, message} <- Conversations.text(input, "message", nil, 8000),
         {:ok, key} <- Conversations.text(input, "request_id", nil, 128),
         mode <- Map.get(input, "deliver_as", "steer"),
         true <- mode in ["follow_up", "steer"],
         true <- source["id"] != target["id"],
         {:ok, entries} <- ConversationTranscriptStore.list(source["id"]) do
      id = "handoff-" <> digest({source["id"], key})

      case Enum.find(entries, &(&1["id"] == id)) do
        nil ->
          with {:ok, handoff_id} <- association(input, entries, source, target["id"], id),
               {:ok, purpose} <- purpose(input, entries, target["id"], handoff_id, trusted) do
            covered_inbound_ids =
              trusted[:covered_inbound_ids] ||
                covered_inbound_ids(entries, target["id"], handoff_id, purpose, context[:run_id])

            fingerprint =
              digest({
                target["id"],
                message,
                mode,
                important,
                input["title"],
                input["handoff_id"],
                purpose
              })

            reserve_and_dispatch(
              id,
              handoff_id,
              fingerprint,
              message,
              mode,
              important,
              context,
              source,
              target,
              purpose,
              covered_inbound_ids,
              trusted[:automatic_report] == true
            )
          end

        existing ->
          with {:ok, purpose} <-
                 purpose(input, entries, target["id"], existing["handoff_id"], trusted) do
            fingerprint =
              digest({
                target["id"],
                message,
                mode,
                important,
                input["title"],
                input["handoff_id"],
                purpose
              })

            if existing["fingerprint"] == fingerprint,
              do: {:ok, receipt(existing)},
              else: {:error, :idempotency_conflict}
          end
      end
    else
      false -> {:error, :handoff_not_permitted}
      error -> error
    end
  end

  defp association(input, entries, _source, peer, id) do
    case input["handoff_id"] do
      nil ->
        {:ok, id}

      handoff_id when is_binary(handoff_id) and byte_size(handoff_id) <= 128 ->
        if Enum.any?(entries, fn entry ->
             (entry["content_type"] == "conversation_handoff" and entry["target"] == peer and
                entry["handoff_id"] == handoff_id) or
               (get_in(entry, ["origin", "kind"]) == "conversation" and
                  get_in(entry, ["origin", "conversation_id"]) == peer and
                  get_in(entry, ["origin", "handoff_id"]) == handoff_id)
           end),
           do: {:ok, handoff_id},
           else: {:error, :invalid_handoff_id}

      _ ->
        {:error, :invalid_handoff_id}
    end
  end

  defp purpose(_input, _entries, _peer, _handoff_id, %{purpose: purpose})
       when purpose in @purposes,
       do: {:ok, purpose}

  defp purpose(%{"purpose" => purpose}, _entries, _peer, _handoff_id, _trusted)
       when purpose in @purposes,
       do: {:ok, purpose}

  defp purpose(%{"purpose" => _purpose}, _entries, _peer, _handoff_id, _trusted),
    do: {:error, :invalid_input}

  defp purpose(input, entries, peer, handoff_id, _trusted) do
    if input["handoff_id"] && not association_initiated_here?(entries, peer, handoff_id),
      do: {:ok, "result"},
      else: {:ok, "request"}
  end

  defp association_initiated_here?(entries, peer, handoff_id) do
    Enum.any?(entries, fn entry ->
      entry["id"] == handoff_id and entry["content_type"] == "conversation_handoff" and
        entry["target"] == peer
    end)
  end

  defp covered_inbound_ids(entries, peer, handoff_id, "result", run_id)
       when is_binary(run_id) do
    entries
    |> Enum.filter(&request_for_run?(&1, peer, handoff_id, run_id))
    |> Enum.map(& &1["id"])
  end

  defp covered_inbound_ids(_entries, _peer, _handoff_id, _purpose, _run_id), do: []

  defp reserve_and_dispatch(
         id,
         handoff_id,
         fingerprint,
         message,
         mode,
         important,
         context,
         source,
         target,
         purpose,
         covered_inbound_ids,
         automatic_report
       ) do
    entry = %{
      "id" => id,
      "content_type" => "conversation_handoff",
      "role" => "system",
      "content" => message,
      "target" => target["id"],
      "fingerprint" => fingerprint,
      "delivery_status" => "delivery_unknown",
      "request_id" => id,
      "handoff_id" => handoff_id,
      "source_conversation" => source["id"],
      "source_run" => context[:run_id],
      "important" => important,
      "purpose" => purpose,
      "covered_inbound_ids" => covered_inbound_ids,
      "automatic_report" => automatic_report
    }

    with {:ok, _entry} <- ConversationTranscriptStore.append(source["id"], entry) do
      result =
        with {:ok, ack} <-
               dispatch(
                 id,
                 handoff_id,
                 message,
                 mode,
                 important,
                 context,
                 source,
                 target,
                 purpose,
                 automatic_report
               ),
             {:ok, updated} <-
               ConversationTranscriptStore.update(source["id"], id, %{
                 "delivery_status" => Atom.to_string(ack.action),
                 "run_id" => ack.run_id
               }) do
          {:ok, receipt(updated)}
        else
          _ -> {:ok, receipt(entry)}
        end

      notify(source["id"])
      notify(target["id"])
      result
    end
  end

  defp dispatch(
         id,
         handoff_id,
         message,
         mode,
         important,
         context,
         source,
         target,
         purpose,
         automatic_report
       ) do
    origin = %{
      "kind" => "conversation",
      "conversation_id" => source["id"],
      "run_id" => context[:run_id],
      "request_id" => id,
      "handoff_id" => handoff_id,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "important" => important,
      "purpose" => purpose,
      "expect_report" => purpose == "request",
      "automatic_report" => automatic_report
    }

    with {:ok, base} <- pinned_run_opts(target, context) do
      if Keyword.has_key?(base, :provider_config) do
        opts =
          base
          |> Keyword.merge(
            workspace_id: source["workspace_id"],
            source: :conversation,
            channel: :conversation,
            origin: origin,
            message_id: id,
            transcript_id: id,
            inbound_id: id,
            deliver_as: if(mode == "follow_up", do: :follow_up, else: :steer),
            tools: Handbean.Agent.default_tools()
          )

        Handbean.Agent.Coordinator.add_message(
          target["id"],
          "[Message from another conversation. Source conversation_id: #{source["id"]}. Handoff_id: #{handoff_id}. Purpose: #{purpose}. Requests consumed by this run receive an automatic terminal report unless explicitly fulfilled with purpose=result. Use the same handoff_id to respond. For reverse questions or answers in a multi-round exchange, set purpose explicitly. Automatic reports do not require a reply. Do not send an empty acknowledgment.]\n" <>
            message,
          opts
        )
      else
        {:error, :missing_runtime_configuration}
      end
    end
  end

  defp pinned_run_opts(target, context) do
    base = (context[:conversation_run_opts] || []) |> Keyword.take(@dispatch_run_opts)
    model_ref = target_model_ref(target, base)

    if is_binary(model_ref) do
      case Handbean.Agent.ModelConfig.resolve_model_for_workspace(
             workspace_path(%{conversation_run_opts: base}),
             model_ref
           ) do
        {:ok, provider_config, model_id} ->
          {:ok,
           base
           |> Keyword.put(:model, composite_model_id(model_ref, model_id))
           |> Keyword.put(:provider_config, provider_config)
           |> put_target_reasoning(target)}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "Model is not allowed: #{inspect(reason)}"}
      end
    else
      {:error, :missing_runtime_configuration}
    end
  end

  defp target_model_ref(target, base) do
    provider = get_in(target, ["collaboration", "provider"])
    model = get_in(target, ["collaboration", "model"])

    cond do
      is_binary(provider) and is_binary(model) ->
        "#{provider}/#{model}"

      composite_model_ref?(target["selected_model"]) ->
        target["selected_model"]

      true ->
        base
        |> Keyword.get(:workspace_path)
        |> Handbean.Agent.ModelConfig.default_model_for_workspace()
    end
  end

  defp composite_model_ref?(model), do: is_binary(model) and String.contains?(model, "/")

  defp composite_model_id(model_ref, model_id) do
    [provider | _rest] = String.split(model_ref, "/", parts: 2)
    "#{provider}/#{model_id}"
  end

  defp put_target_reasoning(opts, %{"selected_reasoning_level" => level})
       when is_binary(level) and level != "",
       do: Keyword.put(opts, :reasoning_level, level)

  defp put_target_reasoning(opts, _target), do: opts

  defp report_terminal(id, status, opts) do
    run_id = opts[:run_id]

    with true <- is_binary(run_id),
         false <- opts[:delegated?] == true,
         {:ok, source} <- ConversationStore.get_metadata(id),
         {:ok, entries} <- ConversationTranscriptStore.list(id) do
      requests = Enum.filter(entries, &request_for_run?(&1, nil, nil, run_id))
      groups = Enum.group_by(requests, &request_group/1)
      normal_completion? = status in [:completed, "completed"]
      exceptional? = not normal_completion?
      covered = covered_request_ids(entries, run_id)

      groups
      |> Enum.map(fn {group, grouped} ->
        pending =
          if exceptional?,
            do: grouped,
            else: Enum.reject(grouped, &MapSet.member?(covered, &1["id"]))

        {group, pending}
      end)
      |> Enum.reject(fn {_group, pending} -> pending == [] end)
      |> Enum.each(fn {{peer, handoff_id}, pending} ->
        send_terminal_report(
          source,
          peer,
          handoff_id,
          Enum.map(pending, & &1["id"]),
          status,
          run_id,
          entries,
          opts,
          exceptional?
        )
      end)
    else
      _ -> :ok
    end
  end

  defp request_for_run?(entry, peer, handoff_id, run_id) do
    origin = entry["origin"] || %{}

    entry["content_type"] == "user_msg" and entry["consumption"] == "consumed" and
      entry["consumed_run_id"] == run_id and origin["kind"] == "conversation" and
      origin["purpose"] == "request" and origin["expect_report"] == true and
      origin["automatic_report"] != true and
      (is_nil(peer) or origin["conversation_id"] == peer) and
      (is_nil(handoff_id) or origin["handoff_id"] == handoff_id)
  end

  defp request_group(entry) do
    origin = entry["origin"]
    {origin["conversation_id"], origin["handoff_id"]}
  end

  defp covered_request_ids(entries, run_id) do
    entries
    |> Enum.filter(fn entry ->
      entry["content_type"] == "conversation_handoff" and entry["source_run"] == run_id and
        entry["purpose"] == "result"
    end)
    |> Enum.flat_map(&List.wrap(&1["covered_inbound_ids"]))
    |> MapSet.new()
  end

  defp send_terminal_report(
         source,
         peer,
         handoff_id,
         inbound_ids,
         status,
         run_id,
         entries,
         opts,
         exceptional?
       ) do
    context = %{
      conversation_id: source["id"],
      workspace_id: source["workspace_id"],
      run_id: run_id,
      conversation_run_opts: opts
    }

    input = %{
      "conversation" => peer,
      "message" => terminal_message(status, run_id, peer, handoff_id, entries, exceptional?),
      "request_id" => automatic_request_id(run_id, peer, handoff_id, status),
      "handoff_id" => handoff_id,
      "deliver_as" => "steer"
    }

    with {:ok, target} <- Conversations.authorize(context, peer) do
      locked(source, fn ->
        deliver(input, context, source, target, true, %{
          purpose: if(exceptional?, do: "notification", else: "result"),
          covered_inbound_ids: if(exceptional?, do: [], else: inbound_ids),
          automatic_report: true
        })
      end)
    end
  end

  defp terminal_message(status, run_id, peer, handoff_id, entries, false) do
    prefix = "Run #{run_id} finished with status #{status}."

    if uniquely_attributable?(entries, run_id, peer, handoff_id) do
      case final_text(entries, run_id) do
        nil -> prefix <> " No non-empty final result was persisted for this request."
        text -> bounded(prefix <> " Final result:\n" <> text)
      end
    else
      prefix <> " The run had mixed inputs, so no unpartitioned final text is attached."
    end
  end

  defp terminal_message(status, run_id, _peer, _handoff_id, _entries, true),
    do:
      "Run #{run_id} ended with status #{status}. No error details are forwarded across conversations."

  defp uniquely_attributable?(entries, run_id, peer, handoff_id) do
    inputs =
      Enum.filter(entries, fn entry ->
        entry["content_type"] == "user_msg" and entry["consumption"] == "consumed" and
          entry["consumed_run_id"] == run_id
      end)

    inputs != [] and Enum.all?(inputs, &request_for_run?(&1, peer, handoff_id, run_id))
  end

  defp final_text(entries, run_id) do
    entries
    |> Enum.filter(fn entry ->
      entry["content_type"] == "assistant_msg" and entry["run_id"] == run_id and
        entry["phase"] in ["final", "final_answer"] and is_binary(entry["content"]) and
        String.trim(entry["content"]) != ""
    end)
    |> List.last()
    |> case do
      nil -> nil
      entry -> entry["content"]
    end
  end

  defp bounded(message), do: String.slice(message, 0, 8_000)

  defp automatic_request_id(run_id, peer, handoff_id, status),
    do: "terminal-" <> digest({run_id, peer, handoff_id, to_string(status)})

  defp receipt(entry),
    do: %{
      conversation: entry["target"],
      message_id: entry["id"],
      handoff_id: entry["handoff_id"],
      delivery: entry["delivery_status"],
      consumption: "unknown; inspect target transcript consumption field",
      note: "accepted/enqueued is not consumed or completed; uncertain dispatch is not replayed"
    }

  defp locked(source, fun),
    do: :global.trans({{__MODULE__, source["workspace_id"]}, self()}, fun)

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  def notify(id),
    do:
      Phoenix.PubSub.broadcast(
        Handbean.PubSub,
        "conversation:updated",
        {:conversation_updated, id}
      )
end
