defmodule Handbean.Schedule.Entry do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]
  schema "schedules" do
    field :workspace_id, :string
    field :conversation_id, :string
    field :name, :string
    field :instruction, :string
    field :rule, :map
    field :time_zone, :string
    field :model, :string
    field :reasoning_level, :string
    field :status, :string, default: "active"
    field :next_run_at, :utc_datetime
    field :version, :integer, default: 1
    field :created_by, :string

    timestamps()
  end
end
