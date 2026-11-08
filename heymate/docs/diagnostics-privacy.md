# Optional diagnostics: schema v2 (#18)

Both categories are off by default. Settings > Privacy & Data provides separate
switches for product diagnostics and crash summaries, plus local JSON previews
and exports. Declining either changes no app capability. The onboarding choice
enables product diagnostics only. A saved choice survives relaunch.

## Destination and release gate

The sender uses a small explicit HTTP schema, not an analytics/crash SDK. No
SDK, replay, autocapture, stack-trace upload or automatic device enrichment is
initialized. The only permitted ingestion destinations are
`https://us.i.posthog.com/batch/` and `https://eu.i.posthog.com/batch/`.
Every request disables PostHog GeoIP enrichment and person profiles. Network
infrastructure can still observe an IP address; these flags are not anonymization.

Product configuration uses `POSTHOG_API_KEY` and `POSTHOG_HOST`. Crash
configuration uses `CRASH_DIAGNOSTICS_API_KEY` and `CRASH_DIAGNOSTICS_HOST`.
These are public project ingestion keys, never personal/admin tokens. A key
must begin with `phc_` or `ph_project_`; unresolved build placeholders and
arbitrary hosts remain inert. One configured category does not configure the
other.

**Release destinations remain disabled until maintainers complete the review
below and set `DIAGNOSTICS_PRIVACY_REVIEWED=v2` in the build.** Source contains
no enabled value, and this work does not enable production collection. Existing
release credentials alone cannot activate v2.

## Inspectable upload schema

Each event has `event`, random `distinct_id`, event `uuid`, UTC `timestamp`, and
`properties`. Transport additionally includes the public project ingestion key.
There are no arbitrary custom property dictionaries at the event entry point.

Common properties:

- `analytics_schema`: 2; `diagnostics_category`: `product` or `crash`.
- `app_version` and `os_version`: numeric dotted versions, otherwise `unknown`.
- `$process_person_profile`: false; `$geoip_disable`: true.

Product events are only `setup_outcome`, `lesson_outcome`, and `mate_outcome`:

- Fixed feature/outcome/provider/failure enums, count clamped to 0–10,000,
  duration in milliseconds clamped to 0–3,600,000.
- Setup completion, skip, and failure during a tour screen question; opening a mate
  with an existing user conversation; walkthrough end, expiry, or inferred
  model-reported completion. A model-reported completion is not evidence that
  a person independently learned or completed the task. `[PLAN:done]` can mean
  stopping, so that directive is recorded as `ended`, not proven success.
- No app-open, message-size, screen coordinates, UI-tap or arbitrary error-domain
  events. Old call sites remain source compatible but do not upload.

`crash_report` adds only `crash_app_version` and a fixed exception category:
`bad_access`, `bad_instruction`, `abort`, `resource`, or `other`.

macOS captures crashes. On the next app launch, after verifying crash consent
and configuration, HeyMate examines its own new `HeyMate-*.ips` files in the
user's DiagnosticReports folder. It checks the bundle identifier, report time,
file size and symbolic-link status, then reconstructs a fresh allowlisted
summary. Old reports, other apps and helper reports are excluded. At most 20
summaries are enqueued per launch. No raw report is attached or uploaded.

Prompts, replies, screenshots, audio, clipboard data, paths, URLs, account or
device identifiers, user tokens, raw error descriptions, breadcrumbs, stack
frames and arbitrary SDK metadata have no serialized field. Preview/export
omits the ingestion key. Previewing never creates an ID or sends anything.

## Identity, queues, retention and opt-out

Each category creates its own random installation UUID only when an allowed
event follows consent and valid configuration. Product ID links participating
installations across sessions to count mate reuse. Crash ID groups repeated
failures in one installation. IDs are independent; no shared account ID,
session identifier, fingerprint, hardware ID or cross-category linking is sent.
Non-UUID values in stored identity preferences are replaced, never uploaded.

Queues contain at most 100 sanitized events in memory; batches contain at most
20. Unsent events vanish on quit. There is no disk upload spool. A single last
sanitized event remains in memory for preview; otherwise preview shows a
labeled synthetic example. The crash cursor prevents duplicate collection;
delivery is best effort, not guaranteed crash accounting.

Opt-out cancels that category's worker and URLSession, drops its unsent events,
preview and ID, and clears its crash collection epoch/cursor. Re-enabling makes
a fresh ID and excludes crashes from before the new consent epoch. Other
category's consent and queue remain independent. Requests already delivered
cannot be recalled. Erase HeyMate data opts out of both categories. macOS owns
its original crash reports; HeyMate does not erase them.

Maintainers must configure **at most 30 days of retention** in each ingestion
project and verify it before enabling the release gate. This client cannot
enforce server retention or erase previously delivered records. No retention
claim is made for analytics delivered by older app versions.

## Executed verification (2026-11-08)

`python3 heymate/script/test_diagnostics.py` compiles the production sender and
uses disposable preferences, synthetic .ips reports and a loopback HTTP
collector. It passes:

- No consent: no request, queue or identity, including after preview.
- Missing endpoints, unsafe hosts and missing privacy review: no sends.
- Separate persisted consent and IDs; enabling one leaves the other off.
- Synthetic prompts, paths, errors, URLs, accounts, tokens and SDK metadata do
  not survive serialized uploads or exported previews.
- Exactly two synthetic envelopes reach the development collector, after
  explicit consent; no real crash or production upload is performed.
- Crash collection excludes historical, unrelated and duplicate reports.
- Opt-out cancels an in-flight request, clears unsent events and ID, and stops
  future sending. Re-enabling does not replay old reports.

## Maintainer privacy review before release configuration

Review remains pending; do not set the release gate until all are recorded:

1. Reviewer and date, event schema approval, and confirmation that lesson
   outcomes are described accurately.
2. Ingestion project/region, separate category configuration and access owners.
3. Retention setting of 30 days or less, deletion/access procedure, and provider
   processing terms. Verify GeoIP/person enrichment remains disabled.
4. Passing probe results and UI review of independent switches, preview/export,
   default-off behavior, unavailable builds and opt-out.
5. App/site privacy copy matching the exact release configuration.
