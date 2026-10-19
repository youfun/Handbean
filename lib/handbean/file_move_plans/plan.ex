defmodule Handbean.FileMovePlans.Plan do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "file_move_plans" do
    field :conversation_id, :string
    field :workspace_id, :string
    field :checkout_path, :string
    field :title, :string
    field :status, :string, default: "draft"
    field :entries, {:array, :map}, default: []
    field :selected_ids, {:array, :string}, default: []
    field :version, :integer, default: 1
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
