defmodule Handbean.Storage.ConversationEntry do
  @moduledoc false

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "conversation_entries" do
    field :conversation_id, :string
    field :entry_id, :string
    field :sequence, :integer
    field :revision, :integer, default: 1
    field :role, :string
    field :content_type, :string
    field :message_type, :string
    field :direction, :string
    field :phase, :string
    field :status, :string
    field :run_id, :string
    field :turn_number, :integer
    field :tool_call_id, :string
    field :tool_status, :string
    field :content, :string
    field :payload, :map, default: %{}
    timestamps()
  end
end
