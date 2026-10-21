defmodule Handbean.Storage.ConversationRun do
  @moduledoc false

  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "conversation_runs" do
    field :conversation_id, :string
    field :run_id, :string
    field :status, :string
    field :stop_reason, :string
    field :loop_owner, :string
    field :backend, :string
    field :model, :string
    field :initial_permission_mode, :string
    field :initial_permission_revision, :integer
    field :initial_approval_mode, :string
    field :initial_approvals_reviewer, :string
    field :permission_source, :string
    field :delegated_approval, :string
    field :current_permission_mode, :string
    field :current_permission_revision, :integer
    field :permission_changed_at, :utc_datetime_usec
    field :error, :string
    field :turn_count, :integer, default: 0
    field :duration_ms, :integer
    field :capture_version, :integer, default: 1
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps()
  end
end
