# A8 routing producer — October 21, 2026

Owner: Yajat. Local routing software and the import tool are implemented. The bundled graph is explicitly synthetic, not a surveyed pilot. Field coverage, calibration, B8 integration, human review and joint M7/G6 acceptance remain open.

`LumaPathRouting` provides versioned/schema-checked pedestrian nodes and directed/bidirectional edges, public segment/side/level identity, geometric shape, length/crossings and independently dated width/stairs/slope/surface/lighting attributes. It requires source/license/attribution/survey provenance. Lighting applicability uses explicit UTC-hour windows; a timestamp outside its validity or applicability becomes unknown. The complete graph has a separate version/publication/expiry boundary.

`RoutePlanner` filters hard constraints first: unknown/stale stairs cannot satisfy avoid-stairs; width uses value minus measurement uncertainty; slope uses value plus uncertainty. A fresh verified community barrier blocks only under the corresponding constraint; unverified evidence cannot establish a closure or width. Latest canonical issue revisions, expiry and side/level identity limit influence. No hard constraint is relaxed automatically.

Nonnegative Dijkstra costs use the specification's initial weights. The unknown-fraction measure in this baseline is lighting coverage, as in the worked example; missing surface data is separately explained and never represented as measured good surface. Produce profile/shorter/documented-lighting objectives and deduplicate alternatives with edge-set Jaccard overlap >=0.8. Deterministic node/edge ordering resolves equal costs. Costs are preference heuristics in equivalent meters, never displayed as traveled length. Complexity uses a simple bounded O(V²) node selection; no device-performance claim is made for maximum graph size.

`OfflineGraphStore` atomically imports validated JSON, checks replacement version, enforces an 8 MB file budget, rejects symlinks/corruption and retains original evidence ages. `lumapath-route-tool` supplies executable validation/import/planning commands. Synthetic graphs require explicit opt-in and cannot silently supply ordinary pilot coverage.

## Executed checks

- `swift test`: **84 tests pass**, including seven routing tests for the worked example, uncertainty/unknown/stale hard constraints, disconnected graph, synthetic/expired coverage refusal, deterministic alternatives, community revision/side/expiry, offline import/corruption/version conflict and invalid graph/weights.
- `swift run lumapath-route-tool validate Evaluation/Routing/worked-example.json` and `plan … start end --synthetic` run on actual source. The profile choice is 460 m with 492.2 equivalent-meter cost; the shorter choice is 400 m with cost 568, a 60 m actual tradeoff.
- An unsigned iOS simulator build is executed with the regenerated Xcode project; **BUILD SUCCEEDED** (`/tmp/lumapath-a8-build.log`). Existing sensor/model gates remain unchanged. No route-following UI or location-adapter work belonging to B8 is claimed.

## Survey/import handoff

Copy `Evaluation/Routing/worked-example.json` only as a schema example. Replace every synthetic coordinate, edge length, observation, source, license/attribution, survey identity and applicability window with actual reviewed public-pilot survey data; select `surveyedPilot` only after that work. Record methodology, uncertainty, permission and environment/session/time. Never import private saved-room maps as public route data. Unknown required attributes block eligibility; outside coverage must remain unavailable. Validate with `swift run lumapath-route-tool validate /path/to/graph.json`, then `import INPUT OUTPUT [--replace VERSION]`. Import does not certify survey correctness or approve a live route.
