defmodule Handbean.Repo.Migrations.CreateConversationStorage do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :string, primary_key: true

      add :scope, :string,
        null: false,
        check: %{name: "conversations_scope_check", expr: "scope IN ('workspace', 'free')"}

      add :workspace_id, :string,
        check: %{
          name: "conversations_workspace_scope_check",
          expr:
            "(scope = 'free' AND workspace_id IS NULL) OR " <>
              "(scope = 'workspace' AND workspace_id IS NOT NULL AND workspace_id <> '')"
        }

      add :visibility, :string,
        null: false,
        default: "user",
        check: %{
          name: "conversations_visibility_check",
          expr: "visibility IN ('user', 'internal')"
        }

      add :parent_conversation_id,
          references(:conversations, type: :string, on_delete: :restrict)

      add :parent_run_id, :string
      add :parent_tool_call_id, :string

      add :title, :string,
        null: false,
        check: %{
          name: "conversations_title_check",
          expr: "length(trim(title)) BETWEEN 1 AND 80"
        }

      add :title_source, :string, null: false, default: "manual"
      add :selected_model, :string
      add :selected_reasoning_level, :string
      add :collaboration, :map
      add :last_run_result, :string
      add :loaded_tools, :text
      add :archived_at, :utc_datetime_usec
      add :pinned_at, :utc_datetime_usec
      add :next_entry_sequence, :integer, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:conversations, [:workspace_id, :archived_at, :updated_at])
    create index(:conversations, [:scope, :archived_at, :updated_at])
    create index(:conversations, [:parent_conversation_id])

    create table(:conversation_entries) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          null: false

      add :entry_id, :string, null: false
      add :sequence, :integer, null: false
      add :revision, :integer, null: false, default: 1
      add :role, :string
      add :content_type, :string
      add :message_type, :string
      add :direction, :string
      add :phase, :string
      add :status, :string
      add :run_id, :string
      add :tool_call_id, :string
      add :tool_status, :string
      add :content, :text
      add :payload, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:conversation_entries, [:conversation_id, :entry_id])
    create unique_index(:conversation_entries, [:conversation_id, :sequence])
    create index(:conversation_entries, [:conversation_id, :run_id, :status])
    create index(:conversation_entries, [:conversation_id, :run_id, :tool_status])

    create index(:conversation_entries, [:conversation_id, :run_id],
             name: :conversation_entries_streaming_assistant_index,
             where: "role = 'assistant' AND status = 'streaming'"
           )

    create index(:conversation_entries, [:conversation_id, :run_id],
             name: :conversation_entries_running_tool_index,
             where: "content_type = 'tool' AND tool_status = 'running'"
           )

    create table(:conversation_editor_states, primary_key: false) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          primary_key: true

      add :editor_files, :text, null: false, default: "[]"
      add :active_file, :string
      add :file_preview_error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create table(:conversation_run_usage) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          null: false

      add :run_id, :string, null: false

      add :source, :string,
        null: false,
        check: %{
          name: "conversation_run_usage_source_check",
          expr: "source IN ('parent', 'delegated', 'unkeyed')"
        }

      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cache_read_tokens, :integer, null: false, default: 0
      add :cache_write_tokens, :integer, null: false, default: 0
      add :total_input_tokens, :integer, null: false, default: 0
      add :usage_incomplete, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_run_usage, [:conversation_id, :source, :run_id])
    create index(:conversation_run_usage, [:conversation_id, :source])

    create table(:operation_receipts) do
      add :scope_kind, :string, null: false
      add :scope_id, :string, null: false
      add :request_id, :string, null: false
      add :fingerprint, :string, null: false

      add :status, :string,
        null: false,
        check: %{
          name: "operation_receipts_status_check",
          expr: "status IN ('reserved', 'completed', 'unknown')"
        }

      add :receipt, :map
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:operation_receipts, [:scope_kind, :scope_id, :request_id])

    create table(:session_snapshots, primary_key: false) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          primary_key: true

      add :seq, :integer, null: false, default: 0
      add :control_events, :map, null: false, default: %{"items" => []}
      add :next_turn_messages, :map, null: false, default: %{"items" => []}
      add :extension_state, :map, null: false, default: %{}
      add :model, :string
      add :snapshot, :map
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
