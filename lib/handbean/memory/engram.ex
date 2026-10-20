defmodule Handbean.Memory.Engram do
  @moduledoc """
  An engram (memory trace) — a semantic record of a fact, pattern, or
  user preference, inspired by the cog-cli memory model.

  Engrams can be short-term (auto-expiring after 24h) or long-term
  (persisted by explicit reinforce).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.Memory.{EngramEvent, Synapse}

  schema "engrams" do
    field :content, :string
    field :kind, Ecto.Enum, values: [:fact, :pattern, :preference, :rule, :context]
    field :short_term, :boolean, default: true
    field :expires_at, :utc_datetime
    field :reinforced_count, :integer, default: 0
    field :last_reinforced_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :revision, :integer, default: 1

    has_many :events, EngramEvent
    has_many :source_synapses, Synapse, foreign_key: :source_id
    has_many :target_synapses, Synapse, foreign_key: :target_id

    timestamps()
  end

  @doc false
  def changeset(engram, attrs, opts \\ []) do
    engram
    |> cast(attrs, [
      :content,
      :kind,
      :short_term,
      :expires_at,
      :reinforced_count,
      :last_reinforced_at,
      :metadata,
      :revision
    ])
    |> validate_required([:content, :kind])
    |> put_expiry(Keyword.get(opts, :ttl_hours, 24))
  end

  defp put_expiry(changeset, ttl_hours) do
    cond do
      not get_field(changeset, :short_term) ->
        put_change(changeset, :expires_at, nil)

      not (is_integer(ttl_hours) and ttl_hours > 0) ->
        add_error(changeset, :expires_at, "ttl_hours must be a positive integer")

      expiry_required?(changeset) ->
        expires_at =
          DateTime.utc_now()
          |> DateTime.add(ttl_hours * 3600, :second)
          |> DateTime.truncate(:second)

        put_change(changeset, :expires_at, expires_at)

      true ->
        changeset
    end
  end

  defp expiry_required?(changeset) do
    Ecto.get_meta(changeset.data, :state) == :built or
      match?({:ok, true}, fetch_change(changeset, :short_term)) or
      is_nil(get_field(changeset, :expires_at))
  end
end
