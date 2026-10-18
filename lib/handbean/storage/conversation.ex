defmodule Handbean.Storage.Conversation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "conversations" do
    field :scope, :string
    field :workspace_id, :string
    field :checkout_path, :string
    field :visibility, :string, default: "user"
    field :parent_conversation_id, :string
    field :parent_run_id, :string
    field :parent_tool_call_id, :string
    field :title, :string
    field :title_source, :string, default: "manual"
    field :selected_model, :string
    field :selected_reasoning_level, :string
    field :collaboration, :map
    field :last_run_result, :string
    field :loaded_tools, :string
    field :status, :string, default: "active"
    field :pending_delete_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :pinned_at, :utc_datetime_usec
    field :next_entry_sequence, :integer, default: 1
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
