defmodule Handbean.Repo.Migrations.CreateEngramsFts do
  use Ecto.Migration

  def up do
    execute """
    CREATE VIRTUAL TABLE engrams_fts USING fts5(
      content,
      content='engrams',
      content_rowid='id',
      tokenize='trigram case_sensitive 0'
    )
    """

    execute """
    CREATE TRIGGER engrams_ai AFTER INSERT ON engrams BEGIN
      INSERT INTO engrams_fts(rowid, content) VALUES (new.id, new.content);
    END
    """

    execute """
    CREATE TRIGGER engrams_ad AFTER DELETE ON engrams BEGIN
      INSERT INTO engrams_fts(engrams_fts, rowid, content)
      VALUES ('delete', old.id, old.content);
    END
    """

    execute """
    CREATE TRIGGER engrams_au AFTER UPDATE ON engrams BEGIN
      INSERT INTO engrams_fts(engrams_fts, rowid, content)
      VALUES ('delete', old.id, old.content);
      INSERT INTO engrams_fts(rowid, content) VALUES (new.id, new.content);
    END
    """

    execute "INSERT INTO engrams_fts(engrams_fts) VALUES ('rebuild')"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS engrams_au"
    execute "DROP TRIGGER IF EXISTS engrams_ad"
    execute "DROP TRIGGER IF EXISTS engrams_ai"
    execute "DROP TABLE IF EXISTS engrams_fts"
  end
end
