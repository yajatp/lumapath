import argparse
import logging
import os
import time
from pathlib import Path
from wsgiref.simple_server import make_server, WSGIRequestHandler
from .assistance import AssistanceProxy, JevTransport
from .auth import IdentityService, OIDCVerifier, UnconfiguredIdentity
from .database import Database
from .http import Application
from .schema import require
from .intelligence import IntelligenceService
from .storage import LocalObjectStorage

class QuietHandler(WSGIRequestHandler):
    def setup(self):
        super().setup(); self.connection.settimeout(10)
    def log_message(self,*args): pass # Application logs only route class, status and random request ID.

def main():
    parser=argparse.ArgumentParser(description='LumaPath local/staging community service; production deployment requires separate review.')
    parser.add_argument('command',choices=['serve','migrate','grant-moderator','run-deletions'])
    parser.add_argument('--data',default='.local-data')
    parser.add_argument('--port',type=int,default=8765)
    parser.add_argument('--user-id')
    parser.add_argument('--reason')
    args=parser.parse_args()
    root=Path(args.data).resolve(); database=Database(root/'community.sqlite3'); storage=LocalObjectStorage(root/'objects')
    service=IntelligenceService(database,storage)
    if args.command=='migrate': print('Schema migrated/validated.'); return
    if args.command=='grant-moderator':
        require(args.user_id and args.reason,400,'userAndReasonRequired')
        with database.transaction() as db:
            require(db.execute('SELECT 1 FROM users WHERE id=?',(args.user_id,)).fetchone() is not None,404,'userNotFound')
            db.execute("UPDATE users SET role='moderator' WHERE id=?",(args.user_id,))
            service._audit(db,None,'operatorCLI','grantModerator',args.reason)
        print('Server-side role assignment audited.'); return
    if args.command=='run-deletions':
        service.run_deletions()
        with database.connect() as db:
            referenced={r[0] for r in db.execute('SELECT evidence_key FROM reports WHERE evidence_key IS NOT NULL UNION SELECT object_key FROM deletion_jobs WHERE object_key IS NOT NULL')}
        storage.reconcile(referenced,time.time()-3600)
        print('Deletion batch and aged orphan reconciliation processed.'); return
    config=[os.environ.get(k) for k in ('LUMAPATH_OIDC_ISSUER','LUMAPATH_OIDC_AUDIENCE','LUMAPATH_OIDC_JWKS_URL')]
    if any(config) and not all(config): raise SystemExit('Configure all three OIDC fields or none.')
    verifier=OIDCVerifier(*config) if all(config) else UnconfiguredIdentity()
    identity=IdentityService(database,verifier)
    secret=os.environ.get('LUMAPATH_TYPESAFE_API_KEY')
    assistance=AssistanceProxy(database,JevTransport(secret) if secret else None,
        model=os.environ.get('LUMAPATH_JEV_MODEL','jev-1.14.0'),
        daily_cap_microusd=int(os.environ.get('LUMAPATH_JEV_DAILY_CAP_MICROUSD','0')),
        request_reserve_microusd=int(os.environ.get('LUMAPATH_JEV_REQUEST_RESERVE_MICROUSD','0')))
    logging.basicConfig(level=logging.INFO,format='%(message)s')
    with make_server('127.0.0.1',args.port,Application(service,identity,assistance),handler_class=QuietHandler) as server:
        print('Local service listening on loopback; external TLS/staging not configured.',flush=True)
        server.serve_forever()

if __name__=='__main__': main()
