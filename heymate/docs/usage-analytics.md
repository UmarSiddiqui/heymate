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

Metric definitions:

- Daily active installs: `active_use`, unique users, daily.
- Weekly active installs: `active_use`, unique users, weekly.
- Activation: first-ever `value_received`. New events represent successful AI responses. Historical cohorts may include shelf saves from older app versions; filter `source_event = ai_response_received` for AI-only activation.
- Retention: first-ever `value_received` as the cohort event; `active_use` as the return event. Show day 1, day 7, day 30 and weekly cohorts.

Optional future charts (not created during initial setup): activation funnel `active_use` → `value_received` by `app_version`, and conversational reliability `response_error` versus `ai_response_received`.

`active_use` accompanies accepted user messages (typed or voice, including Hermes), deliberate notch clicks. Its `source_event` property separates these actions. Launches, hover, idle timers, provider quota polls, and background update checks do not count. `value_received` accompanies successful replies. Shelf-save events are no longer emitted. Scheduled/background agent jobs are excluded from active use. Events carry `app_version`, `analytics_schema: 1`, timestamps and bounded numeric metadata; they never carry message content. Anonymous events set `$process_person_profile: false` and `$geoip_disable: true`. HTTPS requests still expose a network IP to the service in transit.

## Interpretation and limitations

Counts cover opted-in installations only, not all people. Multiple Macs and identity resets can count separately. Existing users can opt in from Privacy & Data. No retrospective data is uploaded. Events retry with backoff in a bounded memory-only queue (100 events); offline app exits or overflow can lose events. This tradeoff avoids leaving analytics history on disk. No SDK autocapture, screen recording, or fingerprinting is started.

If using the free single-project plan, flag synthetic events `is_test: true` and exclude them as above. A dedicated test project is preferable when available. Validate the app flow: launch opted out (no traffic), opt in and send a successful message, relaunch and send again (same distinct ID), opt out (no new sends), then re-opt in (new ID). Build tests use an injected transport and never send production events.

Sources: https://posthog.com/docs/api/capture and https://posthog.com/docs/product-analytics/retention
