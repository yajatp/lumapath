# Local operations and staging handoff

Scope: A14 local drills. No production deployment, TLS endpoint, production restore, provider rotation or rollback has been executed. Stop all service writers before any backup or restore, including deletion workers. The CLI requires --offline as an operator assertion; it cannot prove that another host/process has stopped. Store snapshots encrypted outside the repository, restrict access, and define retention/deletion/replica policies before deployment. Snapshots contain private data. SHA256 detects corruption; it is not snapshot authentication against a malicious operator.

## Backup and restore

```sh
PYTHONPATH=Server python3 -m lumapath_service.operations backup --source path/to/live-data --destination path/to/new-snapshot --offline
PYTHONPATH=Server python3 -m lumapath_service.operations restore --source path/to/new-snapshot --current path/to/stopped-current-data --destination path/to/new-restored-data --offline
```

Source includes community.sqlite3 and objects/. Commands reject existing destinations, nested destinations, corrupt databases, unexpected schema, invalid object names, symlink object files, missing referenced objects and bad hashes. SQLite backup creates a consistent database; stopped writers are required for consistency with object storage. The snapshot manifest contains hashes and names only, not secret configuration. Keep the previous service/data directory intact while validating the new restored directory in isolation.

Restore requires the latest current store. It reapplies post-backup report deletions through the actual IntelligenceService and completes object erasure; it cannot recover deletions lost from *both* the current store and backup. Preserve a separate durable deletion ledger/replica in a real deployment. A restored snapshot is private historical data and is still subject to retention/deletion policy: purging restored output does not erase retained snapshots. Restore revokes all sessions/challenges and resets moderator roles for fresh operator grants. Current assistance spend/quota rows replace snapshot counters, preventing rollback from restoring daily allowance. A snapshot predating these tables is rejected when the current ledger exists; migrate the offline snapshot first. No backup may be exposed directly as a public service. Global public version advances beyond current and snapshot values so clients cannot treat older evidence as current.

Verify no pending deletion jobs, no old sessions, no revived private evidence, no old moderator roles and correct public projections before switching the service to the new directory. Regrant roles with audited CLI, require fresh login, run service tests/readiness and a synthetic private workflow on staging. Local health is not proof that OIDC, provider, TLS or storage permissions work. Reopen traffic only after review.

## Rotation, deployment and rollback

Provider secret is server environment only. Provision a new key through the official console, store in the deployment secret manager, stop writers, replace environment configuration and restart. Check authenticated synthetic staging calls against the pinned model, limits, retention agreement and conservative billing reserve; then revoke old key at the provider. Never place either key in a command line/log/repo. Live provider rotation is pending. Fail-closed behavior with no configured key is locally tested.

OIDC signing keys belong to the identity provider. Restrict configured issuer/audience/JWKS HTTPS origin; never trust URLs in unverified tokens. Rotate in the provider, verify new signature/audience/nonce, and revoke app sessions with offline `DELETE FROM sessions; DELETE FROM challenges;` when incident policy requires. Local signature/revocation tests cover the application boundary; actual identity-provider key rotation is pending.

Before staging deployment: install Python 3.14 and `pip install -r Server/requirements.lock`, pin the deployed source SHA and Python image digest, isolate data/credentials per environment, run migrations and backup, configure TLS/reverse-proxy budgets and a single service process, verify auth/storage/deletion/provider independently. Bind only loopback behind TLS; the bundled WSGI runner is a development server. Production supervision, request total-deadline enforcement, monitoring, encrypted backup, durable deletion journal and deployment image digest remain operator deliverables.

Rollback code to the previously tested SHA only if it supports the current database schema (currently 2 plus optional additive assistance tables). Do not downgrade or overwrite live data to roll code back. Prefer forward fix for incompatible schema; restore to a new isolated directory with the current deletion/spend ledger when required, then verify and switch explicitly. Retain a recovery snapshot until the operator's retention deadline. External deployment/switch/rollback has not been performed.

## Checks

`PYTHONPATH=Server python3 -m unittest discover -s Server/tests -v` includes real local SQLite/object backup, post-backup private evidence deletion/restore, session/role invalidation, persistent spend and corruption/traversal/no-overwrite drills. This supplies local software evidence, not production recovery-time objectives or disaster recovery acceptance.
