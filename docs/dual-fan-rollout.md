# Multi-channel fan telemetry candidate (hardware v9)

This candidate extends the hardware v8 collector from commit b332fb7ec54b6bc87f568af9459489893eed591f. It is **not a fleet deployment**. Public update metadata remains unchanged. Deploy only after the live receiver is upgraded and real-device canaries pass.

## Data contract

Existing report `version: 4`, `reportType: hardwareDaily`, scalar `fanRpm`, hourly `fanCount/fanSum/fanMin/fanMax`, report IDs, delivery policy, and retry acknowledgments remain unchanged. New reports add `hardwareVersion: v9` and `fanSchemaVersion: 2`.

`latest.fans` is an array of independent tachometer channels:

- `identifier`: exact stable LibreHardwareMonitor sensor ID, case-sensitive.
- `name`: descriptive sensor label, not a unique key or proof of physical function.
- `rpm`: finite RPM in [0, 20000], or null. Zero remains a measured zero.
- `status`: `ok`, `unavailable`, `missing`, or `ambiguous` (duplicate ID).

`latest.primaryFanIdentifier` identifies the legacy scalar channel. The existing primary is pinned, so an inventory reorder/disappearance cannot substitute another fan into old history. Every exposed fan channel is collected; none is selected by fastest RPM or guessed from a label. Previously seen channels remain present with null RPM when absent. No second fan or reading is invented on a single-channel device.

Each hourly bucket optionally adds `fans`, keyed by the same identifier. Per channel: `attempts`, `count`, `sum`, `min`, `max`, `zeroCount`, `unavailableCount`, plus `identifier/name`. A channel's mean is `sum / count` only when `count > 0`. Old hourly buckets and pending reports are preserved. New per-channel counts start only when collected; historical scalar readings are not duplicated into two channels.

The local state schema stays at 1 with additive `fanCatalog` and `hardwareVersion` fields. Only fan identifiers and names are retained in the catalog. Existing temperature, CPU usage, SSD, and scalar fan alert rules are unchanged; this change does not add unvalidated alarms for unused motherboard headers.

## Receiver prerequisite (not yet integrated)

Locate the actual bound Apps Script source and current deployment before changing it. Accept both old scalar-only and additive fan-schema reports. Retain the independent channels in raw/history storage and latest view, keyed by Screen ID plus exact sensor ID; never key by label or array position. Render null as unavailable and zero as 0 RPM, without diagnosing a physical fan failure from either alone. Preserve existing sheet columns/history and append or add a separate channel table. Store the received hardware version and last-seen time so deployment can be verified per device.

Tests must cover old and new payloads, duplicate report IDs, payload validation, case-sensitive IDs, equal RPMs, reversed order, zero, null, missing channels, and mixed-version history. Receiver must not acknowledge new fields and silently discard them. Do not transmit production credentials or test against the live sheet with fake device records.

## Safe rollout

1. Run the supplied tests on Windows PowerShell 5.1 (production runtime) and PowerShell 7. Review all failures. A passing mock test is not physical sensor validation.
2. Upgrade and verify the actual receiver/schema/dashboard with production behavior preserved. Use existing credentials; do not create new grants or tokens.
3. Build the ZIP from the seven files under `hardware/`, with the same v8 layout and VERSION.txt = v9. Hash SHA-256 and publish the immutable candidate asset. No private config, tokens, Screen IDs, logs or hardware inventory may enter the public repository.
4. Use the private receiver's existing `hardwareUpdatePlan` per-device allowlist, not a public fleet-wide list. Begin with one known single-fan and one known dual-fan device, chosen from the verified inventory. Prefer `installMissing: false` for already-installed monitors. Preserve mode, daily-v1 policy, schedule, backups, identity, existing outbox, and sensor dependencies. Do not force reboots or interrupt player software.
5. Wait for per-device hardwareVersion v9 telemetry. Compare channel IDs and RPMs with an independent on-device sensor reading for both physical configurations. Confirm disappearance produces null, one stopped/zero channel does not hide behind the other, and a single-channel device gains no invented second reading. Verify one complete daily aggregation and successful exact-report acknowledgment before expansion.
6. Expand in small batches, respecting the existing stagger and 04:15–04:45 Dubai restart exclusion. Track eligible/approved/acknowledged/pending/failed counts. Offline machines remain pending, never counted as updated.
7. Pause on errors; remove affected devices from the v9 private plan and restore backed-up v8 collector code without deleting state/config/history. The updater receipt blocks version downgrades, so use a tested rollback path or publish a higher rollback version. Never rewrite a published version/hash in place.

## Known verification limits

- No live receiver source/deployment or private fleet controls are present in this public repository.
- Exposed tachometer headers do not prove two physical fans, and two physical fans do not guarantee two independent readable RPMs. Label channels by identifier until physical mapping is validated.
- The existing v8 hardware compatibility checks remain unchanged. Unsupported hardware is not silently enabled.
- Publication/CI success is not installation or fleet acknowledgment.
