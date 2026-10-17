defmodule Handbean.Memory.Engram do
  @moduledoc """
  An engram (memory trace) — a semantic record of a fact, pattern, or
  user preference, inspired by the cog-cli memory model.

  Engrams can be short-term (auto-expiring after 24h) or long-term
  (persisted by explicit reinforce).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.Memory.Synapse

  schema "engrams" do
    field :content, :string
    field :kind, Ecto.Enum, values: [:fact, :pattern, :preference, :rule, :context]
    field :short_term, :boolean, default: true
    field :expires_at, :utc_datetime
    field :reinforced_count, :integer, default: 0
    field :last_reinforced_at, :utc_datetime
    field :metadata, :map, default: %{}

    has_many :source_synapses, Synapse, foreign_key: :source_id
    has_many :target_synapses, Synapse, foreign_key: :target_id

    timestamps()
  end

  @doc false
  def changeset(engram, attrs) do
    engram
    |> cast(attrs, [
      :content,
      :kind,
      :short_term,
      :expires_at,
      :reinforced_count,
      :last_reinforced_at,
      :metadata
    ])
    |> validate_required([:content, :kind])
    |> put_expiry()
  end

  defp put_expiry(changeset) do
    if get_field(changeset, :short_term) do
      expires_at =
        DateTime.utc_now() |> DateTime.add(24 * 3600, :second) |> DateTime.truncate(:second)

      put_change(changeset, :expires_at, expires_at)
    else
      put_change(changeset, :expires_at, nil)
    end
  end
end
