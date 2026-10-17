defmodule HandbeanProbe.Platform.IOS do
  @moduledoc """
  iOS host for `HandbeanProbe.Platform` requests.

  Android talks to Kotlin through the JNI `handbean_browser` NIF. That NIF is
  not linked on iOS. Open-URL / share-text / file pick use stock Mob NIFs
  instead; export snapshots and file present stay in this module, then
  deliver the same `{:engine_result, map}` envelope HomeScreen already
  decodes.

  `files_pick` is submitted here and **not** completed. The picker receipt
  (`{:files, :picked, items}` / `{:files, :cancelled}`) is correlated with
  the live `platform_pick_photos` request, copied into the controlled import
  root, and only then replied as attachments.
  """

  alias HandbeanProbe.NativePlatform
  alias HandbeanProbe.Platform.IOS.{Adapter, Import, Registry}

  @spec command(map()) :: {:ok, :async} | {:error, term()}
  def command(mapped) when is_map(mapped) do
    if NativePlatform.ios?() do
      dispatch(mapped)
    else
      {:error, :not_ios}
    end
  end

  def command(_), do: {:error, :invalid_platform_request}

  @doc """
  Consume a Mob file-picker receipt for an in-flight photo pick.

  Returns `:handled` when this process has a live `platform_pick_photos`
  request; otherwise `:ignored` so workspace import can keep the event.
  """
  @spec consume_files_event(:cancelled | {:picked, [term()]}) :: :handled | :ignored
  def consume_files_event(event) do
    case Registry.take_pick(self()) do
      {:ok, session} ->
        complete_pick(session, event)
        :handled

      :error ->
        :ignored
    end
  end

  defp dispatch(%{
         op: op,
         request_id: request_id,
         generation: generation,
         caller: caller,
         payload: payload
       })
       when is_pid(caller) do
    fields = decode_payload(payload)

    case op do
      "platform_open_url" ->
        submit(caller, request_id, generation, fn -> adapter().open_url(fields["url"]) end, %{
          "outcome" => "ui_presented",
          "url" => fields["url"]
        })

      "platform_share_text" ->
        submit(caller, request_id, generation, fn -> adapter().share_text(fields["text"]) end, %{
          "outcome" => "chooser_presented"
        })

      "platform_device_calendar" ->
        reply_error(caller, request_id, generation, "unsupported_on_ios")

      "platform_device_alarm" ->
        reply_error(caller, request_id, generation, "unsupported_on_ios")

      "platform_app_settings" ->
        reply_error(caller, request_id, generation, "unsupported_on_ios")

      "platform_export" ->
        export(caller, request_id, generation, fields)

      "platform_open_snapshot" ->
        present_snapshot(caller, request_id, generation, fields, :open, "ui_presented")

      "platform_share_snapshot" ->
        present_snapshot(caller, request_id, generation, fields, :share, "chooser_presented")

      "platform_pick_photos" ->
        pick_photos(caller, request_id, generation)

      "platform_cancel" ->
        cancel(caller, request_id, generation, fields)

      "platform_cleanup" ->
        cleanup(caller, request_id, generation, fields)

      _ ->
        reply_error(caller, request_id, generation, "unsupported_on_ios")
    end
  end

  defp dispatch(_), do: {:error, :invalid_platform_request}

  defp pick_photos(caller, request_id, generation) do
    case adapter().pick_images() do
      :ok ->
        Registry.put_pick(caller, %{
          request_id: request_id,
          generation: generation,
          caller: caller
        })

        {:ok, :async}

      {:error, reason} ->
        reply_error(caller, request_id, generation, error_reason(reason))
    end
  end

  defp complete_pick(session, event) do
    if session[:cancelled] do
      reply(session.caller, session.request_id, session.generation, %{"cancelled" => true})
    else
      finish_pick(session, event)
    end
  end

  defp finish_pick(session, :cancelled) do
    reply(session.caller, session.request_id, session.generation, %{"cancelled" => true})
  end

  defp finish_pick(session, {:picked, items}) when is_list(items) do
    if items == [] do
      finish_pick(session, :cancelled)
    else
      case Import.import_images(items) do
        {:ok, attachments, errors} ->
          reply(session.caller, session.request_id, session.generation, %{
            "attachments" => attachments,
            "errors" => errors
          })

        {:error, reason} ->
          reply_error(
            session.caller,
            session.request_id,
            session.generation,
            error_reason(reason)
          )
      end
    end
  end

  defp finish_pick(session, _), do: finish_pick(session, :cancelled)

  defp export(caller, request_id, generation, fields) do
    workspace = fields["workspace_path"]
    path = fields["path"]
    owner = fields["owner_request_id"] || request_id

    cond do
      not is_binary(workspace) or workspace == "" ->
        reply_error(caller, request_id, generation, "workspace_required")

      not is_binary(path) or path == "" ->
        reply_error(caller, request_id, generation, "missing_source")

      true ->
        case Registry.put_copy(path, workspace, owner) do
          {:ok, snap} ->
            reply(caller, request_id, generation, snapshot_doc(snap))

          {:error, reason} ->
            reply_error(caller, request_id, generation, error_reason(reason))
        end
    end
  end

  defp present_snapshot(caller, request_id, generation, fields, mode, outcome) do
    snapshot_id = fields["snapshot_id"]
    owner = fields["owner_request_id"] || request_id

    case Registry.fetch(snapshot_id, owner) do
      {:ok, snap} ->
        case adapter().present_file(snap.path, mode) do
          :ok ->
            Registry.mark_handed_off(snapshot_id)
            reply(caller, request_id, generation, %{"outcome" => outcome})

          {:error, reason} ->
            reply_error(caller, request_id, generation, error_reason(reason))
        end

      :error ->
        reply_error(caller, request_id, generation, "file_unavailable")
    end
  end

  defp cancel(caller, request_id, generation, fields) do
    target = fields["target_request_id"] || request_id
    Registry.cancel_pick(caller, target)
    Registry.cancel_owned(target)
    reply(caller, request_id, generation, %{"outcome" => "cancelled"})
  end

  defp cleanup(caller, request_id, generation, fields) do
    snapshot_id = fields["snapshot_id"]
    owner = fields["owner_request_id"] || request_id

    case Registry.cleanup(snapshot_id, owner) do
      :ok -> reply(caller, request_id, generation, %{"outcome" => "cleaned"})
      {:error, reason} -> reply_error(caller, request_id, generation, error_reason(reason))
    end
  end

  defp submit(caller, request_id, generation, fun, ok_doc) do
    case fun.() do
      :ok -> reply(caller, request_id, generation, ok_doc)
      {:error, reason} -> reply_error(caller, request_id, generation, error_reason(reason))
    end
  end

  defp decode_payload(payload) when is_binary(payload) do
    case Handbean.JSON.decode(payload) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_payload(payload) when is_map(payload), do: payload
  defp decode_payload(_), do: %{}

  defp adapter, do: Adapter.current()

  defp snapshot_doc(snap) do
    %{
      "snapshot_id" => snap.snapshot_id,
      "display_name" => snap.display_name,
      "size_bytes" => snap.size_bytes,
      "state" => snap.state,
      "owner_request_id" => snap.owner_request_id,
      "mime" => snap.mime
    }
  end

  defp error_reason(reason) when is_binary(reason) and reason != "", do: reason

  defp error_reason(reason) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp error_reason(reason), do: inspect(reason)

  defp reply(caller, request_id, generation, result) when is_pid(caller) do
    send(
      caller,
      {:engine_result, envelope(request_id, generation, Handbean.JSON.encode!(result))}
    )
    {:ok, :async}
  end

  defp reply_error(caller, request_id, generation, reason) when is_pid(caller) do
    send(caller, {:engine_result, envelope(request_id, generation, nil, reason)})
    {:ok, :async}
  end

  defp envelope(request_id, generation, result, error \\ nil) do
    %{
      request_id: request_id,
      generation: generation,
      result: result,
      error: error
    }
  end
end
