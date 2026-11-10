# Opt-in usage analytics

Analytics requires both a public PostHog project token in the build and explicit user consent. Existing installs default to off. The onboarding checkbox and Settings → Privacy & Data control the same persisted preference. No identity or analytics network session exists before consent. Opt-out cancels requests, drops the memory-only queue, and removes the random install ID; opting in again creates a new ID. Already received events cannot be recalled. Erase HeyMate data also withdraws consent.

## Release configuration

Connected project: [HeyMate, PostHog US](https://us.posthog.com/project/684464). GitHub repository variables `POSTHOG_API_KEY` and `POSTHOG_HOST` are configured. No billing or card was added. Production collection starts only after releasing this code and users opt in.

Create a free PostHog project (no credit card), then set GitHub repository variables `POSTHOG_API_KEY` to its **public project token** and `POSTHOG_HOST` to `https://us.i.posthog.com` or `https://eu.i.posthog.com`. Never use a personal/secret API key. The main release workflow embeds these in Info.plist. No key means no telemetry and a disabled settings toggle. Local builds can supply the same Xcode build settings.

Do not enable billing. PostHog's published free allowance is 1M analytics events/month; without a card usage stops at the allowance. Confirm the account's limits before launch.

## Dashboards: HeyMate usage & retention

- [Usage](https://us.posthog.com/project/684464/dashboard/2252562)
- [Retention](https://us.posthog.com/project/684464/dashboard/2252570)

Saved reports use `is_test is not set`: production events omit this property, while synthetic tests set `is_test = true`. Setup verification events use this flag and `app_version = setup-test`; they are not real users.

Saved charts count unique distinct IDs, not total event counts. Usage includes daily and weekly active installs plus weekly retention; Retention includes weekly and daily (Day 1 through Day 30) first-ever activation cohorts.

Existing saved metric definitions (unchanged by the property addition below):

- Daily active installs: `active_use`, unique users, daily.
- Weekly active installs: `active_use`, unique users, weekly.
- Activation: first-ever `value_received`. New events represent successful AI responses. Historical cohorts may include shelf saves from older app versions; filter `source_event = ai_response_received` for AI-only activation.
- Retention: first-ever `value_received` as the cohort event; `active_use` as the return event. Show day 1, day 7, day 30 and weekly cohorts.

Optional future charts (not created during initial setup): activation funnel `active_use` → `value_received` by `app_version`, and conversational reliability `response_error` versus `ai_response_received`.

`active_use` accompanies message events and deliberate notch clicks. Its `source_event` property separates these actions. Launches, hover, idle timers, provider quota polls, and background update checks do not themselves count. Internal routine and handoff sends also reach the message event; they must be excluded with `interaction_origin = user` for human-use reports. `value_received` accompanies nonempty AI replies; routine replies are excluded by the existing call site, but onboarding, handoffs and automatic continuations can produce replies. A received reply is not proof of a correct answer or a completed user task. Shelf-save events are no longer emitted, but remain in historical data. Events carry `app_version`, `analytics_schema: 1`, timestamps and bounded metadata; they never carry message content. Anonymous events set `$process_person_profile: false` and `$geoip_disable: true`. The 2026-11-08 account audit found an IP-address property on a sampled event despite the GeoIP flag. These two new properties do not change IP handling.

## Interaction classifications

Current source adds two enum-backed properties to existing events. These become available only when this code is released and an opted-in install sends an event; historical events are not backfilled. Event names, emission counts, `source_event`, schema version, consent keys and installation IDs are unchanged. No SDK, person profiles, new events, collection opt-in, dashboard changes or billing changes are introduced. Adding properties does not add to event counts against the existing free-plan allowance.

`interaction_origin` values:

- `user`: a direct user interaction, including typed messages, push-to-talk/hands-free input, deliberate notch opens, and drawing/model buttons.
- `onboarding`: tour events and practice requests, including replays and the first-task composer in the tour.
- `routine`: scheduled routine sends.
- `handoff`: delegated mate sends.
- `automatic`: app launch, observed permission transitions, or automatic walkthrough continuations. A permission transition can be observed by polling; it does not assert a fresh user grant.
- `local_control`: requests through the local control interface and its drawing playback.
- `unknown`: an interaction whose originating path was not classified. Never treat this as human use by default.

`input_mode` values:

- `voice`: a Talk transcript or push-to-talk/hands-free start/release. Starting the mic does not prove a message was submitted.
- `typed`: the text composer, including silent-mode text in the notch and the typed tour first-task request. This describes the entry path, not whether every character was physically typed; pasted text and regenerated messages use that same path.
- `none`: no voice/text input applies, for example launch, a notch/button click, routine, handoff or automatic continuation.
- `unknown`: input mode cannot be established from the originating path. Never derive typed usage by subtracting voice starts from all messages.

Message/reply/error/pointing events inherit the context captured for their response task, including after awaits and in child tasks. Concurrent chats keep separate contexts. A steering message has its own message context, but the eventual reply retains the context that initiated its response turn; these properties do not create per-message outcome correlation. Derived `active_use` and `value_received` events copy the base event's classifications without adding another event. Lifecycle and tour events retain their own classifications rather than inheriting a response's context.

Approved reporting definitions, for later report work (no saved charts changed here):

- Activation: first recorded non-tutorial AI reply, using `value_received` with `source_event = ai_response_received` and `interaction_origin = user`.
- Engagement: another qualifying reply on a different UTC calendar day.
- Retention: weekly meaningful use is primary; Day 1/7/30 support it. Use human message activity (`active_use`, `source_event = user_message_sent`, `interaction_origin = user`) as the meaningful-use return event; show deliberate notch use separately. Read mature cohorts only.
- Voice versus typed chat: break qualifying messages and replies down by `input_mode = voice` or `typed`; keep `none` and `unknown` separate. Do not interpret installation-level conversion as exact per-turn success.

Use `is_test is not set` and the app event allowlist, excluding `app_version = setup-test` and internal `$scout_report_emitted` events. New classification filters intentionally omit legacy events with missing properties; do not silently mix legacy and classified denominators. Version comparisons must preserve that coverage boundary. The additive properties alone do not repair the legacy `onboarding_video_completed` event, which also fires on Skip, or establish that a displayed answer solved the user's task.

## Interpretation and limitations

Counts cover opted-in installations only, not all people. Multiple Macs and identity resets can count separately. Existing users can opt in from Privacy & Data. No retrospective data is uploaded. Events retry with backoff in a bounded memory-only queue (100 events); offline app exits or overflow can lose events. This tradeoff avoids leaving analytics history on disk. No SDK autocapture, screen recording, or fingerprinting is started.

If using the free single-project plan, flag synthetic events `is_test: true` and exclude them as above. A dedicated test project is preferable when available. Validate the app flow: launch opted out (no traffic), opt in and send a successful message, relaunch and send again (same distinct ID), opt out (no new sends), then re-opt in (new ID). Build tests use an injected transport and never send production events.

Run `bash script/test_usage_analytics.sh` from `heymate/` to exercise the production analytics code with disposable defaults and injected transport, without launching the app or sending production events. Tests cover unchanged consent and identity behavior, unchanged base/derived event counts, every bounded context value, unknown fallbacks, overlapping response tasks, child-task context and content exclusion. `./scripts/typecheck.sh --tests` checks full app/test integration in scratch DerivedData without installing or launching its output.

Sources: https://posthog.com/docs/api/capture and https://posthog.com/docs/product-analytics/retention
