#!/usr/bin/env python3
"""Copy legacy configuration and ONLY the production SQLite database.

Preview: python3 scripts/migrate_legacy_data.py
Apply:   python3 scripts/migrate_legacy_data.py --apply
Existing destinations are preserved. Sources are never removed.
"""

import argparse
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import time


def copy_file(source, target, database=False):
    target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix='.legacy-copy-', dir=target.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        if database:
            started = time.monotonic()

            def progress(status, remaining, total):
                if time.monotonic() - started > 120:
                    raise TimeoutError('Database backup exceeded 120 seconds')

            source_db = sqlite3.connect(source.absolute().as_uri() + '?mode=ro', uri=True)
            try:
                target_db = sqlite3.connect(temporary)
                try:
                    source_db.backup(target_db, pages=256, progress=progress)
                    target_db.execute('PRAGMA journal_mode=DELETE')
                    if target_db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                        raise RuntimeError('Database integrity check failed')
                finally:
                    target_db.close()
            finally:
                source_db.close()
        else:
            shutil.copyfile(source, temporary)
            if source.read_bytes() != temporary.read_bytes():
                raise RuntimeError('Configuration copy verification failed')
        # Publish atomically without overwriting an existing destination.
        os.link(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def migrate(home, workspace, apply=False, database_source=None, database_target=None):
    legacy = home / '.handbeam'
    current = home / '.handbean'
    pairs = [(legacy / name, current / name, False)
             for name in ('settings.json', 'models.json', 'auth.json')]
    pairs += [
        (workspace / '.handbeam/settings.jsonc', workspace / '.handbean/settings.jsonc', False),
        (database_source or legacy / 'handbeam.db', database_target or current / 'handbean.db', True),
    ]
    for source, target, database in pairs:
        if target.exists() or target.is_symlink():
            print(f'KEEP existing: {target}')
            continue
        if not source.is_file():
            print(f'MISSING source: {source}')
            continue
        if source.is_symlink() or source.parent.is_symlink() or target.parent.is_symlink():
            raise RuntimeError(f'Refusing symlink path: {source} -> {target}')
        if apply:
            copy_file(source, target, database=database)
            print(f'COPIED and verified: {source} -> {target}')
        else:
            print(f'WOULD COPY: {source} -> {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Perform copies; otherwise preview only')
    parser.add_argument('--home', type=Path, default=Path.home(), help='Home directory containing .handbeam')
    parser.add_argument('--workspace', type=Path, default=Path(__file__).resolve().parent.parent,
                        help='Project directory containing .handbeam/settings.jsonc')
    parser.add_argument('--database-source', type=Path, help='Custom production database source')
    parser.add_argument('--database-target', type=Path, help='Custom production database destination')
    args = parser.parse_args()
    try:
        migrate(args.home.expanduser(), args.workspace.expanduser(), apply=args.apply,
                database_source=args.database_source.expanduser() if args.database_source else None,
                database_target=args.database_target.expanduser() if args.database_target else None)
    except (OSError, sqlite3.Error, RuntimeError, TimeoutError) as error:
        parser.exit(1, f'Migration failed: {error}\n')


if __name__ == '__main__':
    main()
