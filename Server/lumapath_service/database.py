from contextlib import contextmanager
from pathlib import Path
import os
import sqlite3

class Database:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)
        with self.connect() as db:
            version = db.execute('PRAGMA user_version').fetchone()[0]
            if version == 0:
                migration = Path(__file__).resolve().parents[1] / 'migrations' / '001_initial.sql'
                db.executescript('BEGIN IMMEDIATE;\n'+migration.read_text()+'\nCOMMIT;')
                version = 1
            if version == 1:
                migration = Path(__file__).resolve().parents[1] / 'migrations' / '002_intelligence.sql'
                db.executescript('BEGIN IMMEDIATE;\n'+migration.read_text()+'\nCOMMIT;')
            elif version != 2:
                raise RuntimeError('unsupportedDatabaseVersion')
        os.chmod(self.path, 0o600)
    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA busy_timeout=5000')
        try:
            yield db
        finally:
            db.close()
    @contextmanager
    def transaction(self):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            try:
                yield db
                db.execute('COMMIT')
            except BaseException:
                db.execute('ROLLBACK')
                raise
