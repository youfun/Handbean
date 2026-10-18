import contextlib
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from migrate_legacy_data import migrate


class LegacyMigrationTest(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parent.parent / 'tmp'
        scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=scratch, prefix='migration-test-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.home = root / 'home'
        self.workspace = root / 'workspace'
        self.legacy = self.home / '.handbeam'
        self.current = self.home / '.handbean'
        self.legacy.mkdir(parents=True)
        (self.workspace / '.handbeam').mkdir(parents=True)
        for name in ('settings.json', 'models.json', 'auth.json'):
            (self.legacy / name).write_bytes(b'{"fixture": true}\n')
        (self.workspace / '.handbeam/settings.jsonc').write_bytes(b'// fixture\n{}\n')
        (self.legacy / 'workspaces.json').write_text(json.dumps({
            'version': 2,
            'workspaces': [{'id': 'legacy-project', 'path': str(self.workspace)}],
        }))

    def run_migration(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            migrate(self.home, self.workspace, **kwargs)

    def test_preview_does_not_create_destination(self):
        self.run_migration()
        self.assertFalse(self.current.exists())
        self.assertFalse((self.workspace / '.handbean').exists())

    def test_configuration_copies_are_exact_and_existing_files_are_preserved(self):
        self.run_migration(apply=True)
        for name in ('settings.json', 'models.json', 'auth.json', 'workspaces.json'):
            self.assertEqual((self.legacy / name).read_bytes(), (self.current / name).read_bytes())
        self.assertEqual((self.workspace / '.handbean/settings.jsonc').read_bytes(), b'// fixture\n{}\n')
        (self.current / 'settings.json').write_bytes(b'keep existing')
        self.run_migration(apply=True)
        self.assertEqual((self.current / 'settings.json').read_bytes(), b'keep existing')
        self.assertEqual((self.legacy / 'settings.json').read_bytes(), b'{"fixture": true}\n')

    def test_production_backup_includes_live_wal_and_excludes_development_and_test(self):
        source = sqlite3.connect(self.legacy / 'handbeam.db')
        self.addCleanup(source.close)
        source.execute('PRAGMA journal_mode=WAL')
        source.execute('PRAGMA wal_autocheckpoint=0')
        source.execute('CREATE TABLE fixture (value TEXT)')
        source.execute("INSERT INTO fixture VALUES ('committed in WAL')")
        source.commit()
        self.assertGreater((self.legacy / 'handbeam.db-wal').stat().st_size, 0)
        development = self.home / '.handbeam_dev'
        development.mkdir()
        (development / 'handbeam_dev.db').write_bytes(b'leave development unchanged')
        (self.workspace / 'handbeam_test.db').write_bytes(b'leave tests unchanged')
        self.run_migration(apply=True)
        target = sqlite3.connect(self.current / 'handbean.db')
        try:
            self.assertEqual(target.execute('SELECT value FROM fixture').fetchall(), [('committed in WAL',)])
            self.assertEqual(target.execute('PRAGMA integrity_check').fetchall(), [('ok',)])
        finally:
            target.close()
        self.assertEqual(sorted(path.name for path in self.current.iterdir()),
                         ['auth.json', 'handbean.db', 'models.json', 'settings.json', 'workspaces.json'])
        self.assertFalse((self.home / '.handbean_dev').exists())
        self.assertFalse((self.workspace / 'handbean_test.db').exists())
        self.assertEqual((development / 'handbeam_dev.db').read_bytes(), b'leave development unchanged')
        self.assertEqual((self.workspace / 'handbeam_test.db').read_bytes(), b'leave tests unchanged')
        self.assertEqual(source.execute('SELECT count(*) FROM fixture').fetchone(), (1,))

    def create_workspace_conversation(self):
        with sqlite3.connect(self.legacy / 'handbeam.db') as source:
            source.execute('CREATE TABLE conversations (scope TEXT, workspace_id TEXT)')
            source.execute("INSERT INTO conversations VALUES ('workspace', 'legacy-project')")

    def test_workspace_conversations_keep_their_registered_identity(self):
        self.create_workspace_conversation()
        self.run_migration(apply=True)
        registry = json.loads((self.current / 'workspaces.json').read_text())
        with sqlite3.connect(self.current / 'handbean.db') as target:
            conversation_id = target.execute('SELECT workspace_id FROM conversations').fetchone()[0]
        self.assertIn(conversation_id, {item['id'] for item in registry['workspaces']})

    def test_newly_generated_registry_blocks_inconsistent_migration_before_copying(self):
        self.create_workspace_conversation()
        self.current.mkdir()
        target_registry = self.current / 'workspaces.json'
        target_registry.write_text(json.dumps({'workspaces': [{'id': 'new-project'}]}))
        original = target_registry.read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'do not match'):
            self.run_migration(apply=True)
        self.assertEqual(list(self.current.iterdir()), [target_registry])
        self.assertEqual(target_registry.read_bytes(), original)
        self.assertFalse((self.workspace / '.handbean').exists())

    def test_missing_registry_blocks_workspace_database_migration(self):
        self.create_workspace_conversation()
        (self.legacy / 'workspaces.json').unlink()
        with self.assertRaisesRegex(RuntimeError, 'Cannot validate workspace identities'):
            self.run_migration(apply=True)
        self.assertFalse(self.current.exists())

    def test_corrupt_source_is_not_published(self):
        (self.legacy / 'handbeam.db').write_bytes(b'not a database')
        with self.assertRaises(sqlite3.DatabaseError):
            self.run_migration(apply=True)
        self.assertFalse((self.current / 'handbean.db').exists())
        self.assertEqual(list(self.current.glob('.legacy-copy-*')), [])

    def test_custom_database_paths_and_existing_database_preservation(self):
        source_path = self.home / 'custom.db'
        with sqlite3.connect(source_path) as source:
            source.execute('CREATE TABLE fixture (value TEXT)')
            source.execute("INSERT INTO fixture VALUES ('first')")
        target_path = self.home / 'custom-target.db'
        self.run_migration(apply=True, database_source=source_path, database_target=target_path)
        with sqlite3.connect(source_path) as source:
            source.execute("INSERT INTO fixture VALUES ('later')")
        self.run_migration(apply=True, database_source=source_path, database_target=target_path)
        with sqlite3.connect(target_path) as target:
            self.assertEqual(target.execute('SELECT value FROM fixture').fetchall(), [('first',)])
        self.assertFalse((self.current / 'handbean.db').exists())


if __name__ == '__main__':
    unittest.main()
