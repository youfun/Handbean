defmodule HandbeanProbe.AndroidIntent do
  @moduledoc """
  Host `:artifact_delivery_backend` adapter: the thin layer
  between `Handbean.ArtifactDelivery.dispatch/2` (Agent tools) and the platform
  NIF.

  It owns no request shape of its own. `open_url` is
  `HandbeanProbe.Platform.open_url_request/4`; `open_file` / `share_file` are the
  present step of the artifact sequence, `HandbeanProbe.Platform.present_request/6`,
  fed with the snapshot that `HandbeanProbe.NativeArtifactDelivery` pinned at
  approval time (`Handbean.ExportSnapshot.Binding`). The UI tap path builds the
  same requests through the same functions.

  The wait is isolated in a spawned process so the caller's mailbox is never
  drained; the reply is decoded by `HandbeanProbe.Bridge.Inbound.engine_result/1`
  and matched on both `request_id` and wire `generation`. On timeout the
  request is cancelled and `{:error, :timeout}` is returned — never a claimed
  success.
  """

  alias HandbeanProbe.Bridge.Inbound
  alias HandbeanProbe.Platform
  alias HandbeanProbe.Platform.Request

  @await_ms 20_000

  @spec dispatch(map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(command, context) when is_map(command) and is_map(context) do
    generation = context[:composer_generation] || 1

    case command_request(command, generation) do
      {:ok, req} -> await_isolated(req)
      {:error, _} = error -> error
    end
  end

  def dispatch(_, _), do: {:error, :invalid_command}

  defp command_request(%{op: :open_url, url: url}, generation) when is_binary(url) do
    {:ok, Platform.open_url_request(self(), Ecto.UUID.generate(), generation, url)}
  end

  defp command_request(%{op: :device_calendar} = cmd, generation) do
    Platform.device_calendar_request(self(), Ecto.UUID.generate(), generation, cmd)
  end

  defp command_request(%{op: :device_alarm} = cmd, generation) do
    Platform.device_alarm_request(self(), Ecto.UUID.generate(), generation, cmd)
  end

  defp command_request(%{op: op} = cmd, generation) when op in [:open_file, :share_file] do
    snap = Inbound.snapshot(cmd)

    Platform.present_request(
      op,
      self(),
      Ecto.UUID.generate(),
      generation,
      snap.snapshot_id,
      snap.owner_request_id
    )
  end

  defp command_request(_, _), do: {:error, :invalid_command}

  defp await_isolated(%Request{} = req) do
    parent = self()
    ref = make_ref()
    deadline_mono = System.monotonic_time(:millisecond) + await_ms()

    waiter =
      spawn(fn ->
        result = run_wait(req, deadline_mono, parent)
        send(parent, {:android_intent, ref, result})
      end)

    receive do
      {:android_intent, ^ref, result} ->
        result
    after
      remaining_ms(deadline_mono) ->
        Process.exit(waiter, :kill)
        cancel_request(req, parent)
        {:error, :timeout}
    end
  end

  defp run_wait(req, deadline_mono, parent) do
    req = %{req | caller: self()}

    case Platform.start(req) do
      {:ok, :async} ->
        await_until(req, deadline_mono, parent)

      {:ok, map} when is_map(map) ->
        normalize({:ok, map})

      {:error, _} = error ->
        error
    end
  end

  defp await_until(req, deadline_mono, parent) do
    remaining = remaining_ms(deadline_mono)

    if remaining <= 0 do
      cancel_request(req, parent)
      {:error, :timeout}
    else
      receive do
        {:engine_result, map} ->
          case Inbound.engine_result(map) do
            {:ok, %Inbound.EngineResult{request_id: id, generation: gen} = decoded}
            when id == req.request_id and (is_nil(gen) or gen == req.generation) ->
              normalize(decoded.body)

            _ ->
              send(parent, {:engine_result, map})
              await_until(req, deadline_mono, parent)
          end

        {:platform, :result, request_id, result} when request_id == req.request_id ->
          normalize(result)
      after
        remaining ->
          cancel_request(req, parent)
          {:error, :timeout}
      end
    end
  end

  defp cancel_request(req, caller) do
    _ = Platform.cancel(caller, req.request_id, req.generation)
    :ok
  end

  defp remaining_ms(deadline_mono) do
    max(deadline_mono - System.monotonic_time(:millisecond), 0)
  end

  defp await_ms do
    Application.get_env(:handbean_probe, :android_intent_await_ms, @await_ms)
  end

  # Body → the `{:ok, %{outcome: ...}}` contract open_url / open_file / share_file read.
  defp normalize({:ok, map}) when is_map(map) do
    snap = Inbound.snapshot(map)

    case snap.outcome do
      outcome when is_binary(outcome) and outcome != "" ->
        {:ok,
         %{
           outcome: map_error(outcome),
           snapshot_id: snap.snapshot_id,
           owner_request_id: snap.owner_request_id,
           display_name: snap.display_name,
           url: snap.url,
           event_id: snap.event_id,
           calendar_id: snap.calendar_id,
           hour: snap.hour,
           minute: snap.minute,
           calendars: snap.calendars,
           events: snap.events
         }}

      _ ->
        {:error, :timeout}
    end
  end

  defp normalize({:error, reason}) when is_binary(reason) and reason != "",
    do: {:ok, %{outcome: map_error(reason)}}

  defp normalize({:error, reason}), do: {:error, map_error(reason)}
  defp normalize(:cancelled), do: {:ok, %{outcome: "cancelled_before_launch"}}
  defp normalize(_), do: {:error, :timeout}

  defp map_error("activity_not_found"), do: "no_handler"
  defp map_error("permission_denied"), do: "permission_denied"
  defp map_error("needs_foreground"), do: "needs_foreground"
  defp map_error("unknown_snapshot"), do: "file_unavailable"
  defp map_error("invalid_snapshot"), do: "file_unavailable"
  defp map_error("security"), do: "launch_failed"
  defp map_error("timeout"), do: "cancelled_before_launch"
  defp map_error(atom) when is_atom(atom), do: map_error(Atom.to_string(atom))
  defp map_error(other) when is_binary(other), do: other
  defp map_error(_), do: "outcome_unknown"
end
