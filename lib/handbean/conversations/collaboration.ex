defmodule Handbean.Conversations.Collaboration do
  @moduledoc """
  Bounded asynchronous handoffs through Coordinator. Transcript entries are the
  durable outbox and UI projection source, not a second message store.

  A reservation is written before dispatch under a workspace lock. An uncertain
  dispatch is NEVER replayed automatically (at-most-once wakeup). The caller sees
  delivery_unknown and a human may inspect/intervene in the target conversation.
  """
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Conversations, WorkspaceStore}
  alias Handbean.Agent.{ModelConfig, Reasoning}
  alias Handbean.Permissions.Boundary

  # Inspection and handoff only. Mutating, shell, browser, extension, and
  # further-delegation tools stay off this list.
  @read_tools ~w(
    read file_search grep code_search web_fetch skill tool_search mem_recall
    list_models list_conversations find_conversation search_conversations read_conversation
    get_conversation_status get_conversation_trajectory reply_to_parent_conversation
    send_conversation_message
  )

  @purposes ~w(request progress result notification)
  @dispatch_run_opts ~w(transcript_store)a

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
         {:ok, target} <- Conversations.authorize(context, input["conversation"], :send) do
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
           Conversations.validate(
             input,
             ~w(title message request_id workspace model reasoning_level mode)
           ),
         {:ok, source} <- Conversations.identity(context),
         {:ok, target_workspace} <- target_workspace(input["workspace"], source, context),
         true <-
           Boundary.workspace_allowed?(
             context,
             target_workspace["id"],
             :create_conversation
           ),
         {:ok, title} <- Conversations.text(input, "title", nil, 200),
         {:ok, key} <- Conversations.text(input, "request_id", nil, 128),
         {:ok, _} <- Conversations.text(input, "message", nil, 8000),
         {:ok, read_only} <- access(input),
         true <- is_nil(source["collaboration"]),
         {:ok, selection} <- creation_selection(input, source, target_workspace, context) do
      locked(source, fn ->
        id = "delegated-" <> digest({source["id"], key})

        with {:ok, target} <-
               child(
                 source,
                 target_workspace,
                 context,
                 id,
                 title,
                 read_only,
                 selection
               ),
             {:ok, receipt} <-
               deliver(input, context, source, target, false, %{
                 authorization_operation: :create_initial
               }) do
          {:ok,
           Map.merge(receipt, %{
             workspace: target_workspace["id"],
             model: selection.response_model,
             reasoning_level: selection.reasoning_level,
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

  defp target_workspace(requested, source, context) when requested in [nil, ""] do
    with {:ok, workspace} <-
           workspace_facts(source["workspace_id"], source["checkout_path"], context) do
      {:ok, Map.put(workspace, "selected_checkout_path", selected_checkout(workspace, source))}
    end
  end

  defp target_workspace(requested, source, context) when is_binary(requested) do
    if requested == source["workspace_id"] do
      target_workspace(nil, source, context)
    else
      case WorkspaceStore.get(requested) do
        {:ok, workspace} ->
          checkout = workspace["default_checkout_path"] || workspace["path"]
          {:ok, Map.put(workspace, "selected_checkout_path", checkout)}

        _ ->
          {:error, :not_accessible}
      end
    end
  end

  defp target_workspace(_requested, _source, _context), do: {:error, :invalid_input}

  defp workspace_facts(workspace_id, checkout, context) do
    case WorkspaceStore.get(workspace_id) do
      {:ok, workspace} ->
        {:ok, workspace}

      _ ->
        if workspace_id == context[:workspace_id] do
          run_opts = context[:conversation_run_opts] || []

          path =
            Keyword.get(run_opts, :workspace_path) || Keyword.get(run_opts, :working_directory)

          if is_binary(path) and path != "" do
            {:ok,
             %{
               "id" => workspace_id,
               "path" => path,
               "default_checkout_path" =>
                 checkout || Keyword.get(run_opts, :working_directory) || path
             }}
          else
            {:ok,
             %{
               "id" => workspace_id,
               "path" => nil,
               "default_checkout_path" => checkout
             }}
          end
        else
          {:error, :not_found}
        end
    end
  end

  defp selected_checkout(workspace, source) do
    source["checkout_path"] || workspace["default_checkout_path"] || workspace["path"]
  end

  defp creation_selection(input, source, workspace, context) do
    same_workspace? = workspace["id"] == source["workspace_id"]

    inherited_request? = Map.get(input, "model") in [nil, "", "current"]
    reasoning_omitted? = Map.get(input, "reasoning_level") in [nil, ""]
    inherited_model = inherited_model_candidate(source, workspace, context)
    checkout = workspace["selected_checkout_path"]

    with {:ok, requested_model} <- model_selection(input),
         {:ok, model_ref} <-
           selected_model_ref(requested_model, same_workspace?, source, workspace, context),
         {:ok, model} <- available_model(workspace["path"], checkout, model_ref),
         {:ok, _provider_config, model_id} <-
           ModelConfig.resolve_model_for_workspace(workspace["path"], model_ref,
             checkout_path: checkout
           ),
         {:ok, reasoning_level} <-
           selected_reasoning_level(input, model, same_workspace?, source, context) do
      {:ok,
       %{
         model_ref: model_ref,
         provider: model.provider_id,
         model: model_id,
         reasoning_level: reasoning_level,
         pin_runtime: not same_workspace? or not is_nil(requested_model),
         response_model:
           if(same_workspace? and is_nil(requested_model), do: "current", else: model_ref)
       }}
    else
      {:error, :target_model_unavailable}
      when same_workspace? and inherited_request? and is_nil(inherited_model) and
             reasoning_omitted? ->
        {:ok,
         %{
           model_ref: nil,
           provider: nil,
           model: nil,
           reasoning_level: nil,
           pin_runtime: false,
           response_model: "current"
         }}

      {:error, :target_model_unavailable} ->
        model_unavailable(same_workspace?)

      {:error, :invalid_reasoning_level} ->
        {:error, :invalid_reasoning_level}

      _ ->
        model_unavailable(same_workspace?)
    end
  end

  defp model_unavailable(true) do
    {:error, "The requested model is not available. Use list_models to inspect available models."}
  end

  defp model_unavailable(false), do: {:error, :target_model_unavailable}

  defp model_selection(input) do
    model = Map.get(input, "model")

    cond do
      model in [nil, "", "current"] -> {:ok, nil}
      catalog_ref?(model) -> {:ok, model}
      true -> {:error, :invalid_input}
    end
  end

  defp selected_model_ref(nil, true, source, workspace, context) do
    source
    |> inherited_model_candidate(workspace, context)
    |> present_model_ref()
  end

  defp selected_model_ref(nil, false, _source, workspace, _context) do
    workspace["path"]
    |> ModelConfig.strict_default_model_for_workspace(
      checkout_path: workspace["selected_checkout_path"]
    )
    |> present_model_ref()
  end

  defp selected_model_ref(model_ref, _same?, _source, _workspace, _context),
    do: present_model_ref(model_ref)

  defp inherited_model_candidate(source, workspace, context) do
    default =
      case workspace["path"] do
        path when is_binary(path) and path != "" ->
          ModelConfig.default_model_for_workspace(path,
            checkout_path: workspace["selected_checkout_path"]
          )

        _ ->
          nil
      end

    source["selected_model"] || inherited_model_ref(context[:conversation_run_opts]) || default
  end

  defp present_model_ref(model_ref) when is_binary(model_ref) and model_ref != "",
    do: {:ok, model_ref}

  defp present_model_ref(_model_ref), do: {:error, :target_model_unavailable}

  defp available_model(path, checkout, model_ref) do
    case Enum.find(
           ModelConfig.available_models_for_workspace(path, checkout_path: checkout),
           &(&1.id == model_ref)
         ) do
      nil -> {:error, :target_model_unavailable}
      model -> {:ok, model}
    end
  end

  defp selected_reasoning_level(input, model, same_workspace?, source, context) do
    requested = Map.get(input, "reasoning_level")
    supported = Reasoning.supported_levels(model)

    cond do
      is_binary(requested) and requested != "" ->
        if String.valid?(requested) and String.length(requested) <= 32 and requested in supported,
          do: {:ok, requested},
          else: {:error, :invalid_reasoning_level}

      supported == [] ->
        {:ok, nil}

      true ->
        inherited =
          if same_workspace?,
            do:
              source["selected_reasoning_level"] ||
                inherited_reasoning(context[:conversation_run_opts])

        level =
          if inherited in supported,
            do: inherited,
            else: Reasoning.default_level(model)

        if level in supported,
          do: {:ok, level},
          else: {:error, :invalid_reasoning_level}
    end
  end

  defp inherited_reasoning(opts) when is_list(opts), do: Keyword.get(opts, :reasoning_level)
  defp inherited_reasoning(_opts), do: nil

  defp catalog_ref?(value) do
    is_binary(value) and String.valid?(value) and String.length(value) <= 256 and
      String.contains?(value, "/") and not String.contains?(value, ["\n", "\r", "\0"])
  end

  defp child(source, workspace, context, id, title, read_only, selection) do
    spec =
      if selection.pin_runtime do
        %{
          "read_only" => read_only,
          "provider" => selection.provider,
          "model" => selection.model
        }
      else
        %{"read_only" => read_only}
      end

    case ConversationStore.get_metadata(id) do
      {:ok, target} ->
        if child_matches?(target, source["id"], workspace["id"], spec, selection),
          do: {:ok, target},
          else: {:error, :idempotency_conflict}

      _ ->
        ConversationStore.create(workspace["id"],
          id: id,
          title: title,
          parent_conversation_id: source["id"],
          parent_run_id: context[:run_id],
          parent_tool_call_id: context[:tool_call_id],
          checkout_path: workspace["selected_checkout_path"],
          selected_model: selection.model_ref,
          selected_reasoning_level: selection.reasoning_level,
          collaboration: spec
        )
    end
  end

  defp inherited_model_ref(opts) when is_list(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) -> if String.contains?(model, "/"), do: model
      _ -> nil
    end
  end

  defp inherited_model_ref(_opts), do: nil

  defp normalize_optional_handoff(%{"handoff_id" => handoff_id} = input)
       when is_binary(handoff_id) do
    if String.trim(handoff_id) == "", do: Map.delete(input, "handoff_id"), else: input
  end

  defp normalize_optional_handoff(input), do: input

  defp child_matches?(target, parent_id, workspace_id, spec, selection) do
    collab = target["collaboration"] || %{}

    target["workspace_id"] == workspace_id and
      target["selected_model"] == selection.model_ref and
      target["selected_reasoning_level"] == selection.reasoning_level and
      ConversationStore.parent_conversation_id(target) == parent_id and
      collab == spec
  end

  defp deliver(input, context, source, target, important, trusted \\ %{}) do
    authorization_operation = trusted[:authorization_operation] || :send

    with {:ok, source} <- Conversations.authorize(context, source["id"], authorization_operation),
         {:ok, target} <- Conversations.authorize(context, target["id"], authorization_operation),
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
    cross_workspace_return =
      source["workspace_id"] != target["workspace_id"] and purpose == "request" and
        not automatic_report

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
      "automatic_report" => automatic_report,
      "cross_workspace_return" => cross_workspace_return,
      "source_workspace_id" => source["workspace_id"],
      "target_workspace_id" => target["workspace_id"]
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
    cross_workspace_return =
      source["workspace_id"] != target["workspace_id"] and purpose == "request" and
        not automatic_report

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
      "automatic_report" => automatic_report,
      "cross_workspace_return" => cross_workspace_return,
      "source_workspace_id" => source["workspace_id"],
      "target_workspace_id" => target["workspace_id"],
      "return_source_conversation_id" => target["id"],
      "return_target_conversation_id" => source["id"]
    }

    with {:ok, base} <- pinned_run_opts(target, context) do
      if Keyword.has_key?(base, :provider_config) do
        opts =
          base
          |> Keyword.merge(
            workspace_id: target["workspace_id"],
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
    run_opts = context[:conversation_run_opts] || []

    with {:ok, workspace} <-
           workspace_facts(target["workspace_id"], target["checkout_path"], context),
         path when is_binary(path) and path != "" <- workspace["path"],
         checkout when is_binary(checkout) and checkout != "" <-
           target["checkout_path"] || workspace["default_checkout_path"] || path,
         true <- File.dir?(checkout) do
      base =
        run_opts
        |> Keyword.take(@dispatch_run_opts)
        |> Keyword.put(:workspace_path, path)
        |> Keyword.put(:working_directory, checkout)

      model_ref = target_model_ref(target, base)

      if is_binary(model_ref) do
        case ModelConfig.resolve_model_for_workspace(path, model_ref, checkout_path: checkout) do
          {:ok, provider_config, model_id} ->
            {:ok,
             base
             |> Keyword.put(:model, composite_model_id(model_ref, model_id))
             |> Keyword.put(:provider_config, provider_config)
             |> put_target_reasoning(target)}

          {:error, _reason} ->
            {:error, :target_model_unavailable}
        end
      else
        {:error, :target_model_unavailable}
      end
    else
      _ -> {:error, :missing_runtime_configuration}
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
        ModelConfig.default_model_for_workspace(Keyword.get(base, :workspace_path),
          checkout_path: Keyword.get(base, :working_directory)
        )
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
      conversation_run_opts: opts,
      conversation_return_grant:
        terminal_return_grant(source, peer, handoff_id, inbound_ids, entries)
    }

    input = %{
      "conversation" => peer,
      "message" => terminal_message(status, run_id, peer, handoff_id, entries, exceptional?),
      "request_id" => automatic_request_id(run_id, peer, handoff_id, status),
      "handoff_id" => handoff_id,
      "deliver_as" => "steer"
    }

    with {:ok, target} <- Conversations.authorize(context, peer, :automatic_return) do
      locked(source, fn ->
        deliver(input, context, source, target, true, %{
          purpose: if(exceptional?, do: "notification", else: "result"),
          covered_inbound_ids: if(exceptional?, do: [], else: inbound_ids),
          automatic_report: true,
          authorization_operation: :automatic_return
        })
      end)
    end
  end

  defp terminal_return_grant(source, peer, handoff_id, inbound_ids, entries) do
    inbound_ids = MapSet.new(inbound_ids)

    authorized? =
      entries
      |> Enum.filter(&MapSet.member?(inbound_ids, &1["id"]))
      |> case do
        [] ->
          false

        requests ->
          Enum.all?(requests, fn entry ->
            origin = entry["origin"] || %{}

            origin["cross_workspace_return"] == true and
              origin["return_source_conversation_id"] == source["id"] and
              origin["return_target_conversation_id"] == peer and
              origin["handoff_id"] == handoff_id
          end)
      end

    if authorized? do
      %Boundary.ReturnGrant{
        source_conversation_id: source["id"],
        target_conversation_id: peer,
        handoff_id: handoff_id
      }
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
