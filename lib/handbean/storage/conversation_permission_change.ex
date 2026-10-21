defmodule Handbean.Storage.ConversationPermissionChange do
  @moduledoc false

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :changed_at, updated_at: false]

  schema "conversation_permission_changes" do
    field :conversation_id, :string
    field :run_id, :string
    field :from_mode, :string
    field :to_mode, :string
    field :source, :string
    field :revision, :integer
    timestamps()
  end
end
