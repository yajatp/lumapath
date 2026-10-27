# Privacy and research data

The public repository contains source, tests, synthetic examples, model assets with notices, and selected simulator UI screenshots. Development conversations, session logs, personal reference photos, submission drafts, signing material, local databases, and unsigned app packages are excluded.

## Local app workflows

Core camera, enhancement, and bundled object-inference workflows run on the iPhone. On-device speech recognition is requested where supported, with typed input available. Choosing a presentation style does not grant permission or start listening.

Saved notes and experimental spatial archives are local. Explicit Research recording can create sensitive camera/depth exports; keep them outside Git and review them before sharing. Recording does not automatically upload captures. The ignore rules exclude `.lumacapture.json` exports, but review every proposed addition: ignore patterns cannot identify all sensitive content.

## Optional service

The separate community service has authenticated private report/evidence routes and limited public projections. External assistance integrations require separate configuration and consent. They are not part of the default local camera workflow. See [service documentation](../Server/README.md) and [operations](../Server/OPERATIONS.md).

Use environment variables or private local configuration for operator credentials. Do not commit real tokens, identity-provider secrets, signing identities, participant records, private room scans, or service backups. Test identities and synthetic coordinates are examples rather than participant data.

## Reporting a concern

Use GitHub’s private vulnerability-reporting option when available. Do not put credentials, private captures, or participant information in public issues or pull requests. If a real credential is exposed, revoke or rotate it before addressing repository copies.
