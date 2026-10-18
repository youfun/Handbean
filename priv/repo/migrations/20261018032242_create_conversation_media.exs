defmodule Handbean.Repo.Migrations.CreateConversationMedia do
  use Ecto.Migration

  def change do
    create table(:conversation_media, primary_key: false) do
      add :id, :string, primary_key: true

      add :conversation_id,
          references(:conversations, type: :string, on_delete: :restrict),
          null: false

      add :producing_entry_id, :string
      add :producer_tool_call_id, :string, null: false

      add :purpose, :string,
        null: false,
        default: "published",
        check: %{name: "conversation_media_purpose_check", expr: "purpose IN ('published')"}

      add :backend, :string, null: false
      add :storage_key, :string, null: false
      add :mime_type, :string, null: false
      add :filename, :string, null: false

      add :size_bytes, :integer,
        null: false,
        check: %{
          name: "conversation_media_size_bytes_check",
          expr: "size_bytes BETWEEN 1 AND 5000000"
        }

      add :sha256, :string,
        null: false,
        check: %{name: "conversation_media_sha256_check", expr: "length(sha256) = 64"}

      add :status, :string,
        null: false,
        default: "staged",
        check: %{
          name: "conversation_media_status_check",
          expr: "status IN ('staged', 'ready', 'pending_delete')"
        }

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :conversation_media,
             [:conversation_id, :producer_tool_call_id, :sha256],
             name: :conversation_media_idempotency_index
           )

    create unique_index(:conversation_media, [:backend, :storage_key])
    create index(:conversation_media, [:conversation_id, :status])
    create index(:conversation_media, [:status, :updated_at])
    create index(:conversation_media, [:producing_entry_id])

    execute(
      """
      CREATE TRIGGER conversation_media_storage_immutable
      BEFORE UPDATE OF id, conversation_id, producer_tool_call_id, purpose, backend,
                       storage_key, mime_type, filename, size_bytes, sha256
      ON conversation_media
      BEGIN
        SELECT RAISE(ABORT, 'conversation media storage identity is immutable');
      END
      """,
      "DROP TRIGGER conversation_media_storage_immutable"
    )
  end
end
