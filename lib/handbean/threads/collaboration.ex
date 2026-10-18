defmodule Handbean.Threads.Collaboration do
  @moduledoc """
  Bounded asynchronous handoffs through Coordinator. Transcript entries are the
  durable outbox and UI projection source, not a second message store.

  A reservation is written before dispatch under a workspace lock. An uncertain
  dispatch is NEVER replayed automatically (at-most-once wakeup). The caller sees
  delivery_unknown and a human may inspect/intervene in the target conversation.
  """
  alias Handbean.{ConversationStore, ConversationTranscriptStore, Threads}

  # Inspection and handoff only. Mutating, shell, browser, extension, and
  # further-delegation tools stay off this list.
  @read_tools ~w(
    read file_search grep code_search web_fetch skill tool_search mem_recall
    list_models list_threads find_thread read_thread get_thread_status
    get_thread_trajectory reply_to_parent_thread send_thread_message
  )

  def completed(id, result, _opts) do
    status = if is_map(result), do: Map.get(result, :status, :error), else: :error
    ConversationStore.update_meta(id, last_run_result: to_string(status))
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

    with :ok <- Threads.validate(input, ~w(thread message request_id deliver_as handoff_id)),
         {:ok, source} <- Threads.identity(context),
         {:ok, target} <- Threads.authorize(context, input["thread"]) do
      locked(source, fn -> deliver(input, context, source, target, false) end)
    end
  end

  def reply(input, context) do
    input = normalize_optional_handoff(input)

    with :ok <- Threads.validate(input, ~w(message request_id handoff_id)),
         {:ok, source} <- Threads.identity(context),
         parent when is_binary(parent) <- ConversationStore.parent_conversation_id(source),
         {:ok, target} <- Threads.authorize(context, parent) do
      input =
        case input["handoff_id"] || context[:thread_handoff_id] do
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
           Threads.validate(input, ~w(title message request_id model mode)),
         {:ok, source} <- Threads.identity(context),
         {:ok, title} <- Threads.text(input, "title", nil, 200),
         {:ok, key} <- Threads.text(input, "request_id", nil, 128),
         {:ok, _} <- Threads.text(input, "message", nil, 8000),
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
    opts = context[:thread_run_opts] || []
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
    source["selected_model"] || inherited_model_ref(context[:thread_run_opts])
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

  defp deliver(input, context, source, target, important) do
    with {:ok, source} <- Threads.authorize(context, source["id"]),
         {:ok, target} <- Threads.authorize(context, target["id"]),
         {:ok, message} <- Threads.text(input, "message", nil, 8000),
         {:ok, key} <- Threads.text(input, "request_id", nil, 128),
         mode <- Map.get(input, "deliver_as", "steer"),
         true <- mode in ["follow_up", "steer"],
         true <- source["id"] != target["id"],
         {:ok, entries} <- ConversationTranscriptStore.list(source["id"]) do
      id = "handoff-" <> digest({source["id"], key})

      fingerprint =
        digest({target["id"], message, mode, important, input["title"], input["handoff_id"]})

      case Enum.find(entries, &(&1["id"] == id)) do
        nil ->
          with {:ok, handoff_id} <- association(input, entries, source, target["id"], id) do
            reserve_and_dispatch(
              id,
              handoff_id,
              fingerprint,
              message,
              mode,
              important,
              context,
              source,
              target
            )
          end

        %{"fingerprint" => ^fingerprint} = existing ->
          {:ok, receipt(existing)}

        _ ->
          {:error, :idempotency_conflict}
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
             (entry["content_type"] == "thread_handoff" and entry["target"] == peer and
                entry["handoff_id"] == handoff_id) or
               (get_in(entry, ["origin", "kind"]) == "thread" and
                  get_in(entry, ["origin", "conversation_id"]) == peer and
                  get_in(entry, ["origin", "handoff_id"]) == handoff_id)
           end),
           do: {:ok, handoff_id},
           else: {:error, :invalid_handoff_id}

      _ ->
        {:error, :invalid_handoff_id}
    end
  end

  defp reserve_and_dispatch(
         id,
         handoff_id,
         fingerprint,
         message,
         mode,
         important,
         context,
         source,
         target
       ) do
    entry = %{
      "id" => id,
      "content_type" => "thread_handoff",
      "role" => "system",
      "content" => message,
      "target" => target["id"],
      "fingerprint" => fingerprint,
      "delivery_status" => "delivery_unknown",
      "request_id" => id,
      "handoff_id" => handoff_id,
      "source_thread" => source["id"],
      "source_run" => context[:run_id],
      "important" => important
    }

    with {:ok, _entry} <- ConversationTranscriptStore.append(source["id"], entry) do
      result =
        with {:ok, ack} <-
               dispatch(id, handoff_id, message, mode, important, context, source, target),
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

  defp dispatch(id, handoff_id, message, mode, important, context, source, target) do
    origin = %{
      "kind" => "thread",
      "conversation_id" => source["id"],
      "run_id" => context[:run_id],
      "request_id" => id,
      "handoff_id" => handoff_id,
      "sent_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "important" => important
    }

    with {:ok, base} <- pinned_run_opts(target, context) do
      if Keyword.has_key?(base, :provider_config) do
        opts =
          base
          |> Keyword.merge(
            workspace_id: source["workspace_id"],
            source: :thread,
            channel: :thread,
            origin: origin,
            message_id: id,
            transcript_id: id,
            inbound_id: id,
            deliver_as: if(mode == "follow_up", do: :follow_up, else: :steer),
            tools: Handbean.Agent.default_tools()
          )

        Handbean.Agent.Coordinator.add_message(
          target["id"],
          "[Task from another thread. Source conversation_id: #{source["id"]}. Handoff_id: #{handoff_id}. Carry out the requested work. If you choose to respond, call send_thread_message with that explicit source id and handoff_id. No response is automatic or required. Do not send an empty acknowledgment.]\n" <>
            message,
          opts
        )
      else
        {:error, :missing_runtime_configuration}
      end
    end
  end

  defp pinned_run_opts(target, context) do
    base = context[:thread_run_opts] || []
    provider = get_in(target, ["collaboration", "provider"])
    model = get_in(target, ["collaboration", "model"])

    if is_binary(provider) and is_binary(model) do
      case Handbean.Agent.ModelConfig.resolve_model_for_workspace(
             workspace_path(%{thread_run_opts: base}),
             "#{provider}/#{model}"
           ) do
        {:ok, provider_config, model_id} ->
          {:ok,
           base
           |> Keyword.delete(:provider)
           |> Keyword.put(:model, "#{provider}/#{model_id}")
           |> Keyword.put(:provider_config, provider_config)}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "Model is not allowed: #{inspect(reason)}"}
      end
    else
      {:ok, base}
    end
  end

  defp receipt(entry),
    do: %{
      thread: entry["target"],
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
