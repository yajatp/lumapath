# A11 provider review — October 21, 2026

Official sources reviewed (documentation, not authenticated service evidence):

- https://docs.typesafe.ai/api/system-one — fixed POST https://api.typesafe.ai/v1/systemone, bearer auth, state/questions/assets and named answers.
- https://docs.typesafe.ai/primitives/choice — criteria map and choice answer.
- https://docs.typesafe.ai/models — lists jev-1.13.0 and jev-1.14.0; $0.042 per million input tokens, output free. Organization limits require console access. Model availability for this account is unverified. No alias is accepted by the adapter.
- https://docs.typesafe.ai/images and https://docs.typesafe.ai/primitives/box — experimental images/boxes, explicit opt-in header, normalized edges. Box requires 1.14; absent targets still yield a box, so presence is asked separately.
- https://typesafe.ai/legal/terms — website terms dated September 19, 2026; separate service agreements may govern API access. Actual account agreement unavailable.
- https://typesafe.ai/legal/privacy-policy — policy dated November 19, 2025; says submitted input is collected and not used for training/fine tuning. No fixed API deletion interval was verified. Do not claim zero retention; operator must establish contractual retention before private data activation.

Pinned implementation target: jev-1.14.0, internal schema 2, prompt 1. Tested provider version: **none**. Fixtures exercise the documented wire shape but do not prove availability, latency, pricing, account limits or real model quality. No secret or payload was sent remotely. Access, data, and hardware evidence remain unavailable.
