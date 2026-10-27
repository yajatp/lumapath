# LumaPath community service

Python 3.12+; tested locally with Python 3.14.7, PyJWT 2.13.0, cryptography 49.0.0 and Pillow 11.3.0. This optional research service provides authenticated community reports, moderation, and public projections. Account, consent, offline submission, and moderator interfaces are not yet integrated into the iPhone app. No production endpoint is deployed.

```sh
cd Server
python3 -m venv .venv
.venv/bin/pip install -r requirements.lock
.venv/bin/python -m lumapath_service migrate --data .local-data
.venv/bin/python -m lumapath_service serve --data .local-data --port 8765
# From repository root:
PYTHONPATH=Server Server/.venv/bin/python -m unittest discover -s Server/tests -v
```

The included server binds loopback only. SQLite migrations run at startup; unsupported schema versions fail closed. Private data directories/files use 0700/0600. Local filesystem objects are immutable and private; no public static-object directory exists. Database and object storage are abstractions for local/staging evaluation, not a claim of production scale/encryption/availability. Place the WSGI `Application` behind an operator-managed TLS endpoint, bounded production WSGI process, request/body/time limits and private persistent storage before actual staging use. Configure provider and retention/backup/deletion policies separately; a localhost pass does not establish staging acceptance.

## Identity and roles

Set all three operator-controlled environment variables: `LUMAPATH_OIDC_ISSUER`, `LUMAPATH_OIDC_AUDIENCE`, `LUMAPATH_OIDC_JWKS_URL`. Issuer/JWKS must be HTTPS. The service pins RS256, validates signature/issuer/audience/required expiry/issued-at/subject/nonce, bounds identity-token lifetime and checks authorized party for multiple audiences. JWKS comes only from configured provider URL with bounded fetch timeout. [PyJWT verification API](https://pyjwt.readthedocs.io/en/stable/api.html) and [usage](https://pyjwt.readthedocs.io/en/stable/usage.html) informed this adapter. Real provider application/nonce-flow compatibility still needs configured staging evidence.

POST a challenge, supply its nonce to the provider's identity flow, then exchange the signed identity token and nonce. Challenges expire after five minutes and are consumed once transactionally. App credentials are random opaque bearer values with 24-hour expiry, stored only as SHA256 hashes; sessions can be revoked. No unsigned/local-debug login exists. Without provider configuration, identity exchange returns 503. Local sensing/replay remains independent of account/server access.

Roles come from the database, never client token role claims. Bootstrap a moderator only from the server operator CLI after that user has signed in:

```sh
python -m lumapath_service grant-moderator --data .local-data --user-id OPERATOR_SELECTED_USER_ID --reason 'Document actual assignment reason'
```

No HTTP role-assignment API exists. Role assignment and moderation are audited. Moderators cannot review their own reports. Test signing keys exist only in temporary test memory; they are not runtime credentials or a bypass.

## HTTP contract, schema version 1

All JSON requests use `Content-Type: application/json`; protected routes use `Authorization: Bearer APP_CREDENTIAL`. Body budget: 1.5 MB, evidence bytes: 1 MiB, image pixels: 4 million. Unknown fields/types and nonfinite numbers are rejected. Errors return stable code plus random request ID, never raw exception/body/token. Operational logs contain request ID, route class and status only; the built-in access logger is disabled. Responses are `no-store`; evidence is private and uses `nosniff`. No cookie or browser CORS grant is supplied.

| Method | Path | Contract |
| --- | --- | --- |
| GET | `/health` | Database/service health; no secrets or user data |
| POST | `/v1/auth/challenge` | Returns nonce and UTC expiry |
| POST | `/v1/auth/exchange` | `{identityToken, nonce}` → app credential |
| DELETE | `/v1/session` | Revoke current credential |
| POST | `/v1/reports` | Typed report below; required `Idempotency-Key` |
| GET | `/v1/reports/ID` | Author/moderator private detail |
| PATCH | `/v1/reports/ID` | `{expectedRevision, report}`; returns to review |
| DELETE | `/v1/reports/ID` | Owner `{expectedRevision}`; tombstone + deletion job |
| POST | `/v1/reports/ID/evidence` | Owner `{expectedRevision, reviewed:true, mediaType, base64}` |
| GET | `/v1/reports/ID/evidence` | Owner/moderator only, original reviewed bytes |
| POST | `/v1/reports/ID/moderation` | Moderator `{expectedRevision,status,reason,evidenceReference?}` |
| GET | `/v1/moderation/queue` | Moderator bounded priority queue |
| GET | `/v1/public/reports` | Controlled public projection and version/ETag |

Report fields are `category`, `description`, `segmentID`, `side`, `level`, `latitude`, `longitude`, `observedAt` (UTC Unix seconds), `expectedPersistence` (`temporary`, `structural`, `lighting`, `scheduled`), `sourceMode` (`manualPublicLocation`, `reviewedPublicSensorDraft`), and `publicLocationConfirmed:true`. Category is the specification's closed eight-item enum. Description is private free text of 1–1,000 characters. Public output whitelists category/segment/side/level, generalized coordinates, times/status/revision; it omits authors, descriptions, evidence paths and account/contact/session data. Clients must supply only genuinely public segment/pin choices; syntax validation is not a geographic privacy classifier.

Idempotency is scoped to account/key and canonical payload digest. Concurrent duplicate creates return the same report; a different payload with the same key returns 409. A retry of a deleted submission returns 410 and never recreates it. Keys/identity/segment tokens are bounded. Mutations require exact current revision and return 409 on conflict. Editing or attaching evidence invalidates publication and requires new review. Verification requires recorded review reason/evidence reference; an opaque successful response is not verification.

Images must be actual metadata-free PNG/JPEG already reviewed by the user. The server verifies format/dimensions/metadata and rejects rather than silently rewriting reviewed bytes. It does not automatically redact faces/plates or guarantee image-content privacy; clients must provide preview, redaction, and explicit upload consent. No raw video, saved-room archive or auto-upload endpoint is provided.

## Deletion and maintenance

Deletion immediately hides the report and bumps public version, then a retryable job removes evidence/private body and redacts audit reason/evidence references. A minimal tombstone/idempotency digest prevents resurrection; backups need an operator retention policy. Run `python -m lumapath_service run-deletions --data .local-data` regularly in staging. It retries failed deletions and removes unreferenced immutable objects older than one hour, covering crash leftovers without deleting an in-flight attachment. Do not run multiple object reconcilers against inconsistent database snapshots.

Rate limits apply per hashed connection IP, app user and report-create identity; 429 preserves the draft for client backoff. The local process does not trust forwarded-IP headers. A staging ingress needs its own correctly configured network limits. Limits count retries as requests; idempotency prevents duplicate insertion, not quota consumption.

Tests use temporary databases and generated RSA keys, including a real loopback HTTP identity/report roundtrip, concurrent duplicate submissions, invalid signatures/claims/nonce replay, auth/role/object boundaries, invalid private-location payloads, stale revisions, metadata rejection, private/public separation and storage/deletion failures. These establish software behavior, not external provider or production operation.

## Report lifecycle, aggregation, and civic projection

Migration 2 adds canonical issues, member mappings, confirmations, private issue audit, merge undo records and schedule applicability. Existing version-1 data migrates and backfills transactionally. The main service uses `IntelligenceService`, which retains the existing authorization and storage boundaries.

Initial condition validity: obstruction/other concerns 24 hours; poor lighting 7 days; structural surface/curb/stair issues 30 days. Entrance restrictions use an explicit `restrictionSchedule` when persistence is `scheduled`: `{startsAt, endsAt, applicableUTCHours}` with Unix UTC seconds and 0–23 UTC hours, bounded to at most seven days after observation. A scheduled claim without actual bounds is rejected; legacy claims missing them become stale. Outside stated hours it is `inactive` for route influence. Feed TTL ends at schedule/start/end/hour boundaries, and applicability changes bump evidence version/revision. These validity intervals are hypotheses needing pilot moderation/field calibration.

Duplicate candidates share category + public segment + side + level and overlap in time. Coordinates alone never merge across street sides/floors. Reports remain independent private records behind a canonical issue. Only public/current observations contribute to current independent-observer counts. Confirmations are unique per account/canonical issue, including merged aliases; authors cannot independently confirm their own issue. Confirmations expire after at most 24 hours and never extend condition validity or automatically verify a report. Observer/confirmation counts reveal no identities.

A dispute immediately downgrades routing until a moderator reviews it with reason and evidence reference. Issue-wide review cannot verify an issue authored by that moderator. Resolution is a recorded moderator transition; reopening requires a newer observation, referenced new evidence, exact report revision and new review. Merging is moderator-only with category/segment/side/level/time and revision checks; undo restores recorded report memberships. Original confirmation records remain associated with their original issues; later confirmations of a merged target stay on that target after undo. Public counts deduplicate aliases. This is a review workflow, not automatic adjudication.

| Method | Path | Contract |
| --- | --- | --- |
| GET | `/v1/public/issues` | Public list/map data, status/category/bbox filter; sort recency or distance |
| GET | `/v1/public/route-evidence` | Versioned canonical evidence, generated/valid-until UTC times, completeness and coverage |
| GET | `/v1/public/civic-export` | `format=geojson`, `csv`, or `text`; no personal text/identity/private evidence |
| POST | `/v1/issues/ID/confirmations` | Authenticated `{observedAt}`; one active independent vote |
| POST | `/v1/issues/ID/disputes` | Authenticated `{expectedRevision,reason}` |
| POST | `/v1/issues/ID/review` | Moderator `{expectedRevision,status,reason,evidenceReference?}` |
| POST | `/v1/reports/ID/reopen` | Owner `{expectedRevision,report,evidenceReference}` |
| POST | `/v1/issues/ID/merge` | Moderator target ID plus `{expectedRevision,sourceID,sourceRevision,reason}` |
| POST | `/v1/issues/ID/unmerge` | Moderator source ID plus `{expectedRevision,targetRevision,reason}` |
| GET | `/v1/issues/ID/history` | Moderator issue/revision/membership/merge pointer/private review history |

Query fields: `minLat,minLon,maxLat,maxLon` as a complete box; `sort=recency|distance`; distance requires `latitude,longitude`; optional `status,category,limit` (integer 1–100). Distance is computed from generalized public coordinates, so repeated queries cannot recover the more precise selected pin. Query locations are not persisted or logged. The list marks truncation; civic export refuses truncated selections and requires a narrower area/filter rather than silently omitting issues. CSV escapes formula-leading text. Text/GeoJSON/CSV include current applicability and observed dates. Export generation returns an artifact to the caller; it does not send anything to a civic authority or imply repair.

Public responses are always no-store. Report changes, deletion, dispute/review, merges, expiry, vote expiry and schedule boundaries invalidate the public version. Public reads run expiry before returning. A production maintenance scheduler is still an operator responsibility; request-time expiry provides correctness even between runs. No staging scheduler has been deployed.

`CommunityEvidenceFeed` in `LumaPathRouting` decodes the real service DTO using Unix-second dates. It rejects older versions, future/stale timestamps, incomplete/filtered coverage, duplicate issue IDs and invalid barrier states. An unfiltered complete feed covers all public issues; a filtered feed must not be reused as complete coverage for an arbitrary graph. TTL is at most five minutes and ends earlier at relevant evidence/schedule boundaries. Wrapped route plans retain the exact feed version/times. Known side/level identities bind evidence; verified obstruction/entrance barriers can block the relevant constraint, fresh unverified issues add only a small caution, and disputed/expired/resolved/inactive issues have zero verified influence. Reports never establish a measured width, accessible path, safe crossing or current local obstacle.

`Evaluation/Community/` contains synthetic examples generated by the actual service. They contain no real survey/user report and are not submissions. The Swift fixture `LumaPathRoutingTests/Fixtures/community-feed.json` is likewise an actual service projection from generated test data.

## Optional assistance proxy

Authenticated `POST /v1/assistance/{attention,intent,classification,image}` routes use the existing bearer sessions. `lumapath_service.assistance` defines the exact task schemas, limits and closed enums. All require schemaVersion 2, requestId/sessionId, nonnegative generation/sourceSequence/goalRevision/profileRevision, budgetMs and textConsent=true. Attention additionally uses the specification's goal/detail/candidates/allowedSelections; candidates contain only id/kind/bearing/evidence and must be currently observed nonurgent observations. Intent/classification use text (2,000 characters maximum). Image requires imageConsent=true, researchOnly=true, frameId, supported target and image {format: png|jpeg, base64}; maximum 700,000 encoded characters / 4 million pixels. Review/redact before sending. No arbitrary URLs or client prompts, models or credentials are forwarded.

Responses echo all freshness references; image echoes its original frameId. Selection, intent/target/detail, category/review, or presence/box fields include separate provider confidence. Classification is always suggestionOnly/humanReviewRequired. Image is always researchOnly; absent presence yields null box. Clients must independently reject cancelled/stale/consent-revoked responses and enforce local observation freshness. The proxy has no authority over local geometry, alerts, report publication, recipients or routes. The native client is responsible for original-frame depth association.

Server-only environment configuration: LUMAPATH_TYPESAFE_API_KEY, LUMAPATH_JEV_MODEL (default pinned jev-1.14.0), LUMAPATH_JEV_DAILY_CAP_MICROUSD, LUMAPATH_JEV_REQUEST_RESERVE_MICROUSD. Both monetary values default to zero (disabled). Set a conservative per-request upper bound after verifying current billing and worst-case input expansion, including images; reservations are never refunded, even for errors. The cap bounds **reserved** spend, not a provider invoice guarantee unless this upper bound has been established. No automatic retries. Per-user quotas: attention 30/minute, intent 10/minute, classification 10/day, image 5/hour. Quotas/reservations are transactional and persist in SQLite; one in-flight request per user/task. Three failed calls open a 60-second circuit. Socket timeouts and elapsed response rejection enforce fallback; mobile must enforce its own end-to-end deadline.

Deploy as a single service process: in-flight/circuit state is process-local and restarts reset the circuit. Multiple workers require shared circuit/in-flight coordination before activation. TLS/reverse-proxy limits remain operator responsibilities. Failures return redacted typed errors; no raw provider result, text, token or image is logged. [Provider review](../Evaluation/Cloud/provider-review.md) records external blockers and official policy sources. No live provider calls have been made.
