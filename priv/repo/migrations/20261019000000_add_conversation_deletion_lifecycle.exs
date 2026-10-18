defmodule Handbean.Repo.Migrations.AddConversationDeletionLifecycle do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :status, :string,
        null: false,
        default: "active",
        check: %{
          name: "conversations_status_check",
          expr: "status IN ('active', 'pending_delete')"
        }

      add :pending_delete_at, :utc_datetime_usec
    end

    create index(:conversations, [:status, :pending_delete_at])

    execute(
      """
      CREATE TRIGGER conversations_require_active_parent_on_insert
      BEFORE INSERT ON conversations
      WHEN NEW.parent_conversation_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM conversations
         WHERE id = NEW.parent_conversation_id AND status = 'active'
       )
      BEGIN
        SELECT RAISE(ABORT, 'parent conversation is unavailable');
      END
      """,
      "DROP TRIGGER conversations_require_active_parent_on_insert"
    )

    execute(
      """
      CREATE TRIGGER conversations_require_active_parent_on_update
      BEFORE UPDATE OF parent_conversation_id ON conversations
      WHEN NEW.parent_conversation_id IS NOT NULL
       AND NOT EXISTS (
         SELECT 1 FROM conversations
         WHERE id = NEW.parent_conversation_id AND status = 'active'
       )
      BEGIN
        SELECT RAISE(ABORT, 'parent conversation is unavailable');
      END
      """,
      "DROP TRIGGER conversations_require_active_parent_on_update"
    )

    execute(
      """
      CREATE TRIGGER conversation_media_require_active_conversation_on_insert
      BEFORE INSERT ON conversation_media
      WHEN NOT EXISTS (
        SELECT 1 FROM conversations
        WHERE id = NEW.conversation_id AND status = 'active'
      )
      BEGIN
        SELECT RAISE(ABORT, 'conversation is pending delete');
      END
      """,
      "DROP TRIGGER conversation_media_require_active_conversation_on_insert"
    )

    execute(
      """
      CREATE TRIGGER conversation_media_require_valid_status_transition
      BEFORE UPDATE OF status ON conversation_media
      WHEN (OLD.status = 'pending_delete' AND NEW.status <> 'pending_delete')
        OR (
          NEW.status IN ('staged', 'ready')
          AND NOT EXISTS (
            SELECT 1 FROM conversations
            WHERE id = NEW.conversation_id AND status = 'active'
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid conversation media status transition');
      END
      """,
      "DROP TRIGGER conversation_media_require_valid_status_transition"
    )
  end
end
