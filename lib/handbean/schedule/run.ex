defmodule Handbean.Schedule.Run do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]
  schema "schedule_runs" do
    field :schedule_id, :string
    field :slot_at, :utc_datetime
    field :kind, :string
    field :request_id, :string
    field :status, :string
    field :reason, :string
    field :run_id, :string

    timestamps()
  end
end
