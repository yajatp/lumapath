"""Offline local operations; never restores over an existing directory."""
from contextlib import closing
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
from .auth import Principal
from .database import Database
from .intelligence import IntelligenceService
from .storage import LocalObjectStorage

def checksum(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def source_database(root):
    path=root/'community.sqlite3'
    if not path.is_file() or path.is_symlink(): raise ValueError('Existing regular community database required')
    db=sqlite3.connect(f'{path.as_uri()}?mode=ro',uri=True)
    if db.execute('PRAGMA integrity_check').fetchone()[0]!='ok' or db.execute('PRAGMA foreign_key_check').fetchall():
        db.close(); raise ValueError('Database integrity failed')
    if db.execute('PRAGMA user_version').fetchone()[0]!=2: db.close(); raise ValueError('Unsupported database schema')
    return db

def backup(root, destination):
    root=Path(root).resolve(); destination=Path(destination).resolve()
    if destination.exists() or destination.is_relative_to(root): raise ValueError('Backup needs a new directory outside live data')
    with closing(source_database(root)) as source:
        destination.mkdir(parents=True,mode=0o700)
        try:
            with sqlite3.connect(destination/'community.sqlite3') as target: source.backup(target)
            objects=LocalObjectStorage(destination/'objects')
            for (key,) in source.execute('SELECT evidence_key FROM reports WHERE evidence_key IS NOT NULL UNION SELECT object_key FROM deletion_jobs WHERE object_key IS NOT NULL'):
                original=LocalObjectStorage(root/'objects').path(key)
                if not original.is_file(): raise ValueError('Referenced object missing')
                shutil.copyfile(original,objects.path(key)); os.chmod(objects.path(key),0o600)
            os.chmod(destination/'community.sqlite3',0o600)
            manifest={str(p.relative_to(destination)):checksum(p) for p in destination.rglob('*') if p.is_file()}
            (destination/'manifest.json').write_text(json.dumps(dict(schemaVersion=1,files=manifest),sort_keys=True,indent=2)+'\n')
            os.chmod(destination/'manifest.json',0o600)
        except BaseException:
            shutil.rmtree(destination); raise
    return dict(files=len(manifest),schemaVersion=2)

def restore(snapshot, current, destination):
    snapshot=Path(snapshot).resolve(); current=Path(current).resolve(); destination=Path(destination).resolve()
    if destination.exists() or destination.is_relative_to(current) or destination.is_relative_to(snapshot): raise ValueError('Restore needs a new isolated directory')
    manifest=json.loads((snapshot/'manifest.json').read_text())
    if manifest.get('schemaVersion')!=1 or not isinstance(manifest.get('files'),dict): raise ValueError('Invalid backup manifest')
    for name,expected in manifest['files'].items():
        path=snapshot/name
        parts=Path(name).parts
        if name!='community.sqlite3' and not (len(parts)==2 and parts[0]=='objects' and len(parts[1])==64 and all(c in '0123456789abcdef' for c in parts[1])):
            raise ValueError('Invalid backup path')
        if path.is_symlink() or not path.is_file() or checksum(path)!=expected: raise ValueError('Backup integrity failed')
    if 'community.sqlite3' not in manifest['files']: raise ValueError('Backup database missing')
    # Current store is mandatory: never resurrect post-backup deletions or reset billed usage.
    with closing(source_database(current)) as live:
        deleted={r[0] for r in live.execute('SELECT id FROM reports WHERE deleted=1')}
        public_version=live.execute("SELECT value FROM metadata WHERE key='public_version'").fetchone()[0]
        usage={}
        for table in ('assistance_usage','assistance_quota'):
            if live.execute('SELECT 1 FROM sqlite_master WHERE type=\'table\' AND name=?',(table,)).fetchone():
                usage[table]=live.execute('SELECT * FROM '+table).fetchall()
        backup(snapshot,destination)
        try:
            database=Database(destination/'community.sqlite3'); service=IntelligenceService(database,LocalObjectStorage(destination/'objects'))
            with database.connect() as db:
                rows=[dict(r) for r in db.execute('SELECT id,author_id,revision FROM reports WHERE deleted=0')]
            for row in rows:
                if row['id'] in deleted: service.delete(Principal(row['author_id'],'user'),row['id'],row['revision'])
            service.run_deletions()
            with database.transaction() as db:
                if db.execute('SELECT 1 FROM deletion_jobs WHERE completed=0').fetchone(): raise ValueError('Restore has incomplete deletion jobs')
                db.execute('DELETE FROM sessions'); db.execute('DELETE FROM challenges')
                db.execute("UPDATE users SET role='user'") # explicit fresh moderator grant after rollback
                db.execute("UPDATE metadata SET value=MAX(value,?)+1 WHERE key='public_version'",(public_version,))
                for table,rows in usage.items():
                    columns=2 if table=='assistance_usage' else 4
                    # Current counters are authoritative; restored rows cannot reset a cap.
                    if not db.execute('SELECT 1 FROM sqlite_master WHERE type=\'table\' AND name=?',(table,)).fetchone():
                        # Initialize outside this transaction below instead.
                        raise ValueError('Backup predates assistance ledger; migrate snapshot before restoring')
                    db.execute('DELETE FROM '+table)
                    db.executemany('INSERT INTO '+table+' VALUES('+','.join('?'*columns)+')',rows)
            # Remove the now-stale copied hash manifest; create a fresh inventory for the drill output.
            (destination/'manifest.json').unlink()
        except BaseException:
            shutil.rmtree(destination); raise
    return dict(deletionsReapplied=len(deleted),sessionsRevoked=True,moderatorRegrantRequired=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description='Stop service writers before offline backup/restore; snapshots contain private data.')
    parser.add_argument('command',choices=['backup','restore']); parser.add_argument('--source',required=True,type=Path)
    parser.add_argument('--destination',required=True,type=Path); parser.add_argument('--current',type=Path)
    parser.add_argument('--offline',action='store_true',required=True,help='Operator confirms all writers are stopped')
    args=parser.parse_args()
    if args.command=='backup': result=backup(args.source,args.destination)
    else:
        if args.current is None: parser.error('--current is required to preserve deletion and spend state')
        result=restore(args.source,args.current,args.destination)
    print(json.dumps(result,sort_keys=True))
