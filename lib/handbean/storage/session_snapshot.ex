defmodule Handbean.Storage.SessionSnapshot do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:conversation_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "session_snapshots" do
    field :seq, :integer, default: 0
    field :control_events, :map, default: %{"items" => []}
    field :next_turn_messages, :map, default: %{"items" => []}
    field :extension_state, :map, default: %{}
    field :model, :string

    # Keeps the SessionStore behaviour lossless while the materialized fields
    # above remain available to recovery queries.
    field :snapshot, :map

    timestamps(inserted_at: false)
  end
end
