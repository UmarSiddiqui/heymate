# CodeNotch source boundary

Upstream: https://github.com/vinzdg/codenotch

Pinned revision: `6522e9f3ee0fe35d46e428b441e6e80b586eacbb`.
License: MIT; the complete notice is shipped as `HeyMate/Codenotch-LICENSE.txt`.
`upstream-manifest.json` records original source paths and SHA-256 hashes.
`CN` prefixes isolate imported types from HeyMate. This directory is a curated,
vendored core, not an independent copy of the upstream application.

## Reused components

- `NotchMotion`, `SideNotchShape`, and `NotchEdge`: physical springs and actual
  animatable, curvature-ramped silhouette. The AppKit frame animator samples the
  same spring; frame width is capped at its destination to preserve camera slots.
- `ProviderRing`/`SpinningArc` and `ActivitySummary`: separate usage/activity
  layers, optional weekly ring, stale treatment, quota warning bands, blocked
  weekly state, finite refresh spin, and layer-based activity animation.
- `UsageModel`: count-aware `LimitWindow`, `Percent`, and fidelity vocabulary.
- Gemini CLI/OpenCode/Hermes accounting, OpenCode schema and credentials,
  Antigravity quota/bridge/transcript readers, Kimi quotas/wire states, Copilot
  quotas, Grok credentials/billing, GLM credentials/quota and ZCode cipher,
  Ollama/LM Studio model listings, read-only SQLite helpers.
- Session display models, process identity checks, Gemini CLI activity,
  Antigravity transcript states, Kimi wire states, Cursor composer headers,
  Claude session records and Codex rollout lifecycle parser.
- Generic provider-order reconciliation. Applicable upstream display choices
  are hosted in HeyMate preferences, with existing HeyMate defaults preserved.

## Deliberate host adaptations

`CNCompatibility.swift` supplies English display copy, HeyMate's dark palette,
small value types and shape constants. `NotchCodenotchReader` owns transport and
maps imported windows to backward-compatible HeyMate cache records.
`NotchProviderCatalog` is the explicit supported capability registry.

All readers run off the main actor. `CNReadBudget` bounds directory entries,
file bytes, SQL work, and scan time. Hitting a budget rejects the entire reading,
never a partial total. SQL opens read-only and cannot use immutable fallback
when a WAL exists. Network transports refuse redirects; credential endpoints
are fixed to each owning provider. OpenCode console metadata cannot redirect
credentials. Antigravity discovery only accepts its own IDE/CLI processes;
self-signed TLS trust is scoped to discovered ports on literal 127.0.0.1.

No upstream app lifecycle, updater/feed, phone server, browser sign-in,
credential renewal, hook installer, execution backend, or owned background
language server is imported. `gh auth token` is intentionally disabled during
credential discovery; an explicit environment token or hosts.yml token is used.
The IDE/CLI must run for Antigravity quota; local counts are the labelled fallback.
Session details, runtime model names and credentials are never cached. Tokens
never enter logs or analytics. Derived/count metrics never gain quota arcs.

Invalid booleans, negative/non-finite quota numbers and missing Copilot numerators
are rejected. Antigravity waits without process evidence expire. Existing
Codex/Claude/Cursor credentials and custom-source Keychain service remain intact.

HeyMate supports macOS 14.2. Only APIs available there are used. The upstream
macOS 15 application target and unrelated settings are not dependencies.

## Updating

1. Review a prospective upstream revision before changing the pin. Never run its
   app or install scripts as part of an update.
2. Run `python3 script/codenotch_source_diff.py /path/to/upstream-checkout` to
   compare each pinned original against its adapted local source. This command
   verifies the checkout revision and hashes, and prints source diffs. Keep
   transport/privacy/scan adaptations when reconciling changes.
3. Reconcile fixture tests in `HeyMateTests/Codenotch` and integration tests.
   Those files retain source-derived payloads, token deduplication, quota/count,
   credential ownership, SQLite WAL, calendar and activity-state cases.
4. Run `script/test_notch_core.sh`, `scripts/typecheck.sh --tests` and workflow
   checks. Use `script/build_and_run.sh --verify` for the canonical signed app.

Additional CodeNotch providers are not advertised until a real, audited reader
and accurate UI mapping are integrated. In particular this is not full upstream
provider/profile, local-runtime speed/relay, or session-hook parity.
