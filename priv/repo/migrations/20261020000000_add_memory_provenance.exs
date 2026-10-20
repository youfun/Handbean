defmodule Handbean.Repo.Migrations.AddMemoryProvenance do
  use Ecto.Migration

  def up do
    alter table(:engrams) do
      add :revision, :integer, null: false, default: 1
    end

    execute("""
    CREATE INDEX engrams_scope_workspace_index
    ON engrams (
      json_extract(metadata, '$.scope'),
      json_extract(metadata, '$.workspace_id')
    )
    """)

    create table(:engram_events) do
      add :engram_id, references(:engrams, on_delete: :delete_all), null: false
      add :engram_revision, :integer, null: false

      add :kind, :string,
        null: false,
        check: %{
          name: "engram_events_kind_check",
          expr: "kind IN ('created', 'updated', 'reinforced', 'observed', 'imported')"
        }

      add :actor, :string,
        null: false,
        check: %{
          name: "engram_events_actor_check",
          expr: "actor IN ('agent_tool', 'reflector', 'user_ui', 'system', 'legacy')"
        }

      add :operation_conversation_id, :string
      add :operation_run_id, :string
      add :operation_tool_call_id, :string
      add :idempotency_key, :string
      add :metadata, :map, null: false, default: %{}
      timestamps()
    end

    create index(:engram_events, [:engram_id, :id])
    create unique_index(:engram_events, [:idempotency_key])

    create table(:engram_provenances) do
      add :event_id, references(:engram_events, on_delete: :delete_all), null: false

      add :relation, :string,
        null: false,
        check: %{
          name: "engram_provenances_relation_check",
          expr: "relation IN ('trigger', 'citation', 'coverage')"
        }

      add :source_kind, :string,
        null: false,
        check: %{
          name: "engram_provenances_source_kind_check",
          expr: "source_kind IN ('entry', 'entry_range', 'checkpoint')"
        }

      add :source_workspace_id, :string, null: false
      add :source_conversation_id, :string, null: false

      add :start_conversation_entry_id,
          references(:conversation_entries, on_delete: :nilify_all)

      add :end_conversation_entry_id,
          references(:conversation_entries, on_delete: :nilify_all)

      add :start_entry_id, :string, null: false
      add :start_sequence, :integer, null: false
      add :start_revision, :integer, null: false
      add :end_entry_id, :string, null: false
      add :end_sequence, :integer, null: false
      add :end_revision, :integer, null: false
      add :member_count, :integer, null: false
      add :anchor_digest, :string, null: false

      add :fidelity, :string,
        null: false,
        check: %{
          name: "engram_provenances_fidelity_check",
          expr: "fidelity IN ('exact', 'legacy_coarse')"
        }

      timestamps()
    end

    create index(:engram_provenances, [:event_id, :id])
    create index(:engram_provenances, [:start_conversation_entry_id])
    create index(:engram_provenances, [:end_conversation_entry_id])
    create index(:engram_provenances, [:source_workspace_id, :source_conversation_id])

    # Existing metadata only names coarse operation context. It cannot prove an
    # exact entry or range, so migration records an imported legacy event and no
    # fabricated source anchor.
    execute("""
    INSERT INTO engram_events (
      engram_id,
      engram_revision,
      kind,
      actor,
      operation_conversation_id,
      operation_run_id,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      revision,
      'imported',
      'legacy',
      CASE
        WHEN json_type(metadata, '$.conversation_id') = 'text'
          THEN json_extract(metadata, '$.conversation_id')
        ELSE NULL
      END,
      CASE
        WHEN json_type(metadata, '$.run_id') = 'text'
          THEN json_extract(metadata, '$.run_id')
        ELSE NULL
      END,
      json_object(
        'source', json_extract(metadata, '$.source'),
        'checkpoint_id', json_extract(metadata, '$.checkpoint_id'),
        'legacy_metadata_snapshot', json(COALESCE(metadata, '{}'))
      ),
      inserted_at,
      updated_at
    FROM engrams
    """)

    execute("""
    UPDATE engrams
    SET metadata = json_remove(
      COALESCE(metadata, '{}'),
      '$.source',
      '$.conversation_id',
      '$.run_id',
      '$.checkpoint_id'
    )
    """)
  end

  def down do
    # Restore the exact pre-migration metadata snapshot for rows imported by up/0
    # before removing the audit tables. Memories created after this migration do
    # not have an imported event and are left unchanged.
    execute("""
    UPDATE engrams
    SET metadata = COALESCE(
      (
        SELECT json_extract(event.metadata, '$.legacy_metadata_snapshot')
        FROM engram_events AS event
        WHERE event.engram_id = engrams.id
          AND event.kind = 'imported'
          AND event.actor = 'legacy'
        ORDER BY event.id ASC
        LIMIT 1
      ),
      metadata
    )
    WHERE EXISTS (
      SELECT 1
      FROM engram_events AS event
      WHERE event.engram_id = engrams.id
        AND event.kind = 'imported'
        AND event.actor = 'legacy'
        AND json_type(event.metadata, '$.legacy_metadata_snapshot') = 'object'
    )
    """)

    drop table(:engram_provenances)
    drop table(:engram_events)

    execute("DROP INDEX engrams_scope_workspace_index")

    alter table(:engrams) do
      remove :revision
    end
  end
end
