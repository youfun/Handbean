defmodule Handbean.Memory.Synapse do
  @moduledoc """
  A synapse connects two engrams, representing an association between them.

  Synapses have a strength that decays over time and a kind label
  (e.g., :related, :contradicts, :example_of, :context_for).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.Memory.Engram

  schema "synapses" do
    belongs_to :source, Engram
    belongs_to :target, Engram

    field :kind, Ecto.Enum,
      values: [:related, :contradicts, :example_of, :context_for, :reinforces]

    field :strength, :float, default: 1.0
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(synapse, attrs) do
    synapse
    |> cast(attrs, [:source_id, :target_id, :kind, :strength, :metadata])
    |> validate_required([:source_id, :target_id, :kind])
    |> unique_constraint([:source_id, :target_id, :kind])
  end
end
