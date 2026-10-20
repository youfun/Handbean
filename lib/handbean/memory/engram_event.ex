defmodule Handbean.Memory.EngramEvent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.Memory.{Engram, EngramProvenance}

  @kinds [:created, :updated, :reinforced, :observed, :imported]
  @actors [:agent_tool, :reflector, :user_ui, :system, :legacy]

  schema "engram_events" do
    belongs_to :engram, Engram
    field :engram_revision, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :actor, Ecto.Enum, values: @actors
    field :operation_conversation_id, :string
    field :operation_run_id, :string
    field :operation_tool_call_id, :string
    field :idempotency_key, :string
    field :metadata, :map, default: %{}

    has_many :provenances, EngramProvenance, foreign_key: :event_id

    timestamps()
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :engram_id,
      :engram_revision,
      :kind,
      :actor,
      :operation_conversation_id,
      :operation_run_id,
      :operation_tool_call_id,
      :idempotency_key,
      :metadata
    ])
    |> validate_required([:engram_id, :engram_revision, :kind, :actor])
    |> validate_number(:engram_revision, greater_than: 0)
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:engram_id)
  end
end
