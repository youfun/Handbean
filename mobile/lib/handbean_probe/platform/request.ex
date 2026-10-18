defmodule HandbeanProbe.Platform.Request do
  @moduledoc """
  Typed platform command. Only these fields are sent to the NIF.
  """

  @enforce_keys [:op, :request_id, :generation, :caller]
  defstruct [:op, :request_id, :generation, :caller, payload: %{}]

  @type t :: %__MODULE__{
          op: String.t(),
          request_id: String.t(),
          generation: integer(),
          caller: pid(),
          payload: map()
        }

  @ops ~w(
    platform_import
    platform_export
    platform_share_snapshot
    platform_open_snapshot
    platform_save_snapshot
    platform_cleanup
    platform_cancel
    platform_pick_photos
    platform_share_discard
    platform_open_url
    platform_share_text
    platform_device_calendar
    platform_device_alarm
    platform_app_settings
  )

  def ops, do: @ops

  def new(op, request_id, generation, caller, payload \\ %{})
      when op in @ops and is_binary(request_id) and is_integer(generation) and is_pid(caller) and
             is_map(payload) do
    %__MODULE__{
      op: op,
      request_id: request_id,
      generation: generation,
      caller: caller,
      payload: payload
    }
  end

  def for_kind(kind, ctx, caller, extra \\ %{})

  def for_kind(:cancel, ctx, caller, _extra) when is_map(ctx) and is_pid(caller) do
    command_id = Ecto.UUID.generate()

    {:ok,
     new("platform_cancel", command_id, ctx.composer_generation, caller, %{
       "op" => "platform_cancel",
       "target_request_id" => ctx.request_id
     })}
  end

  def for_kind(kind, ctx, caller, extra) when is_map(ctx) and is_pid(caller) and is_map(extra) do
    op =
      case kind do
        :import -> "platform_import"
        :export -> "platform_export"
        :share_snapshot -> "platform_share_snapshot"
        :open_snapshot -> "platform_open_snapshot"
        :save_snapshot -> "platform_save_snapshot"
        :cleanup -> "platform_cleanup"
        :pick_photos -> "platform_pick_photos"
        :share_discard -> "platform_share_discard"
        :share_text -> "platform_share_text"
        _ -> nil
      end

    if op in @ops do
      {:ok,
       new(
         op,
         ctx.request_id,
         ctx.composer_generation,
         caller,
         base_payload(op, ctx)
         |> Map.merge(import_fields(kind, extra))
       )}
    else
      {:error, :unknown_op}
    end
  end

  defp base_payload(op, ctx) do
    %{
      "op" => op,
      "workspace_id" => ctx.workspace_id,
      "conversation_id" => ctx.conversation_id
    }
  end

  defp import_fields(:import, extra) do
    extra
    |> stringify()
    |> Map.take(["path", "display_name", "mime"])
  end

  defp import_fields(:share_discard, extra) do
    extra
    |> stringify()
    |> Map.take(["intake_id"])
  end

  defp import_fields(:share_text, extra) do
    extra
    |> stringify()
    |> Map.take(["text"])
  end

  defp import_fields(_, _), do: %{}

  defp stringify(extra) do
    Map.new(extra, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
