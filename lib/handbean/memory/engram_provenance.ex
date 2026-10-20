defmodule Handbean.Memory.EngramProvenance do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.Memory.EngramEvent
  alias Handbean.Storage.ConversationEntry

  schema "engram_provenances" do
    belongs_to :event, EngramEvent
    field :relation, Ecto.Enum, values: [:trigger, :citation, :coverage]
    field :source_kind, Ecto.Enum, values: [:entry, :entry_range, :checkpoint]
    field :source_workspace_id, :string
    field :source_conversation_id, :string

    belongs_to :start_conversation_entry, ConversationEntry
    belongs_to :end_conversation_entry, ConversationEntry

    field :start_entry_id, :string
    field :start_sequence, :integer
    field :start_revision, :integer
    field :end_entry_id, :string
    field :end_sequence, :integer
    field :end_revision, :integer
    field :member_count, :integer
    field :anchor_digest, :string
    field :fidelity, Ecto.Enum, values: [:exact, :legacy_coarse]

    timestamps()
  end

  @doc false
  def changeset(provenance, attrs) do
    provenance
    |> cast(attrs, [
      :event_id,
      :relation,
      :source_kind,
      :source_workspace_id,
      :source_conversation_id,
      :start_conversation_entry_id,
      :end_conversation_entry_id,
      :start_entry_id,
      :start_sequence,
      :start_revision,
      :end_entry_id,
      :end_sequence,
      :end_revision,
      :member_count,
      :anchor_digest,
      :fidelity
    ])
    |> validate_required([
      :event_id,
      :relation,
      :source_kind,
      :source_workspace_id,
      :source_conversation_id,
      :start_entry_id,
      :start_sequence,
      :start_revision,
      :end_entry_id,
      :end_sequence,
      :end_revision,
      :member_count,
      :anchor_digest,
      :fidelity
    ])
    |> validate_number(:start_sequence, greater_than: 0)
    |> validate_number(:start_revision, greater_than: 0)
    |> validate_number(:end_sequence, greater_than: 0)
    |> validate_number(:end_revision, greater_than: 0)
    |> validate_number(:member_count, greater_than: 0)
    |> validate_sequence_range()
    |> foreign_key_constraint(:event_id)
    |> foreign_key_constraint(:start_conversation_entry_id)
    |> foreign_key_constraint(:end_conversation_entry_id)
  end

  defp validate_sequence_range(changeset) do
    case {get_field(changeset, :start_sequence), get_field(changeset, :end_sequence)} do
      {start_sequence, end_sequence}
      when is_integer(start_sequence) and is_integer(end_sequence) and
             end_sequence < start_sequence ->
        add_error(changeset, :end_sequence, "must be greater than or equal to start sequence")

      _range ->
        changeset
    end
  end
end
