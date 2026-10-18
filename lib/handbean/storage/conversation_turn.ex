defmodule Handbean.Storage.ConversationTurn do
  @moduledoc false

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "conversation_turns" do
    field :conversation_id, :string
    field :run_id, :string
    field :turn_number, :integer
    field :status, :string
    field :stop_reason, :string
    field :duration_ms, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end
end
