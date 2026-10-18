defmodule Handbean.Storage.ConversationMedia do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "conversation_media" do
    field :conversation_id, :string
    field :producing_entry_id, :string
    field :producer_tool_call_id, :string
    field :purpose, :string, default: "published"
    field :backend, :string
    field :storage_key, :string
    field :mime_type, :string
    field :filename, :string
    field :size_bytes, :integer
    field :sha256, :string
    field :status, :string, default: "staged"

    timestamps()
  end

  @type t :: %__MODULE__{
          id: String.t(),
          conversation_id: String.t(),
          producing_entry_id: String.t() | nil,
          producer_tool_call_id: String.t(),
          purpose: String.t(),
          backend: String.t(),
          storage_key: String.t(),
          mime_type: String.t(),
          filename: String.t(),
          size_bytes: pos_integer(),
          sha256: String.t(),
          status: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @create_fields ~w(
    id conversation_id producer_tool_call_id purpose backend storage_key mime_type
    filename size_bytes sha256 status
  )a

  @required_fields ~w(
    id conversation_id producer_tool_call_id purpose backend storage_key mime_type
    filename size_bytes sha256 status
  )a

  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(media, attrs) do
    media
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:purpose, ["published"])
    |> validate_inclusion(:mime_type, ~w(image/png image/jpeg image/gif image/webp))
    |> validate_inclusion(:status, ["staged"])
    |> validate_number(:size_bytes, greater_than: 0, less_than_or_equal_to: 5_000_000)
    |> validate_format(:sha256, ~r/\A[a-f0-9]{64}\z/)
    |> validate_length(:filename, min: 1, max: 255)
    |> unique_constraint([:conversation_id, :producer_tool_call_id, :sha256],
      name: :conversation_media_idempotency_index
    )
    |> unique_constraint([:backend, :storage_key])
    |> foreign_key_constraint(:conversation_id)
  end
end
