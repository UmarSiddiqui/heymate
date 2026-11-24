# Verified HeyMate accounts (unreleased)

## Provisioned project

- Firebase project: `heymate-a4aee` (HeyMate), Spark/no billing upgrade.
- Apple client: `com.heymate.app`, nickname HeyMate for Mac.
- Firebase Authentication: Google enabled. Email/password remains enabled for existing sessions; the native signup screen now offers Google only. Anonymous and other social providers remain disabled.
- Firestore: Standard `(default)` database, `australia-southeast1` (Sydney).
- Google Analytics and Gemini were disabled during project creation.
- `HeyMate/FirebaseAccount.plist` contains only the project ID and public client API key. It is not an Admin SDK credential. No server secrets belong in the app.

## iPhone companion pilot

The Spark project has a Firebase Apple app named **HeyMate for iPhone**, bundle ID `com.heymate.app.ios`. Build the `HeyMatePhone` scheme in `HeyMate.xcodeproj`. Its public client configuration comes from [`firebase/ios/GoogleService-Info.plist`](../../firebase/ios/GoogleService-Info.plist). The Mac uses its own Firebase configuration.

The live Firestore rules reserve `companionPilot/{uid}/pairs/{pairId}/tasks/{taskId}`. To enroll a consenting tester, a project administrator sets the `enabled` boolean to `true` on `companionPilot/{Firebase UID}`. Clients need the matching verified Firebase account and cannot modify enrollment. Setting `enabled` to `false` blocks further queue access.

On Mac, open **Settings → Devices → iPhone companion** and choose **Show pairing code**. Sign in on iPhone with the same Google account, then scan the QR in HeyMate or paste the code. The invitation expires in five minutes. **Local browser access** on the same Devices page has its own QR and code.

Pairing gives the iPhone access to chats, profiles, routines, and questions for HeyMate and all active mates, including mates added later. It also lets the iPhone send messages, answer questions, and manage routines. Older pairings keep their existing scope until **Enable workspace access** is chosen on the Mac. Tap **Refresh from Mac** on iPhone to reload the workspace. Security-sensitive approvals and account sign-ins stay on the Mac. **Continue on Mac** opens the same conversation at your desk. **Unpair** on the Mac revokes access. **Forget this Mac** on iPhone erases its pairing and local activity.

- Create a task with `version: 1`, `status: queued`, `requestEnvelope` (28 to 8,192 bytes), and server timestamps for `createdAt` and `updatedAt`. Generate and retain a random task ID before submitting so a retry can check the same task.
- A worker claims it by changing `queued` to `running`, then publishes `completed` or `failed` with `resultEnvelope` (28 to 32,768 bytes). Every update uses a server timestamp for `updatedAt`. The request envelope and creation timestamp are immutable. Queries require a limit of 50 documents or fewer. Clients can delete queued or finished tasks.
- A one-use invitation authenticates Curve25519 key agreement. Both apps keep the derived key in Keychain and use ChaCha20-Poly1305 with the account, pair, task ID, and message direction as authenticated context. Firestore can see IDs, timestamps, status, and envelope sizes. The Mac claims work with an update-time precondition and reports interrupted reads as failed instead of silently repeating them.
- The iPhone polls for active requests while foregrounded and deletes delivered results after saving them locally. The Mac checks every 10 seconds while idle and every 3 seconds during pairing or an active iPhone chat turn. Keep HeyMate open on an awake, online Mac. Measure polling reads before increasing the tester count. An open iPhone chat refreshes automatically while the app is in the foreground. A new chat opens locally and the Mac creates it when the first message arrives. The phone retrieves chat text in pages, with long messages shown as excerpts. Live screen context, the Mac’s file browser, and full desktop settings stay on the Mac.

The chat composer lists brains signed in on the paired Mac, with model and effort choices from the Mac catalog. A selection applies to messages sent from that open chat. The mate’s saved brain stays in effect when no override is selected.

The iPhone can send up to six files or photos, totaling up to 25 MiB per message. Each upload is split into authenticated encrypted chunks in the pair’s `attachmentChunks` collection. The verified, enrolled account can create, read, and delete its chunks. The Mac copies documents to the receiving mate’s inbox and uses its existing image attachment path for photos. The worker deletes chunks after processing. The phone also attempts cleanup when an upload fails.

The iPhone composer shows Stop Reply when the Mac reports a running chat turn. The encrypted stop request identifies the exact turn, so an old request cannot cancel a newer reply in the same chat. Stop Reply leaves the user’s message in history and leaves independent routines and handoffs alone.

A chat sent from iPhone can show a Live Activity on the Lock Screen and Dynamic Island. It shows generic status and opens the conversation when tapped. Turn it off under Connection in the iPhone app. With APNs configured, the Mac sends a status-only completion update when a tracked iPhone turn ends, even while iOS suspends HeyMate. The iPhone includes its per-activity push token in the encrypted chat request when available. Foreground sync continues to update the activity when no token or APNs credentials are available. The Quick Chat widget opens a new HeyMate draft from the Home or Lock Screen. Neither surface shows chat contents.

For the internal pilot, use separate Apple Developer APNs topic-specific keys restricted to `com.heymate.app.ios`. The USB development build uses Sandbox. TestFlight uses Production. Store the credentials only on the paired Mac in `~/Library/Application Support/heymate/phone-live-activity-apns.json`, with owner-only permissions (`0600`). The top-level keys are `sandbox` and `production`. Each entry has `teamID`, `keyID`, and `privateKey` (the contents of its .p8 file). The worker reads this file on demand. Never include it in the iPhone bundle or commit it. APNs receives the activity token and generic reply status.

Run the transport smoke test from the repository root with Xcode, Node, and Java 21 available. The test uses a temporary Firebase Auth account and a synthetic Emily result in the local emulators.

```bash
swiftc heymate/HeyMate/PhonePilot/PhonePilotProtocol.swift \
  heymate/HeyMate/PhonePilot/PhonePilotMailbox.swift \
  firebase/phone-pilot.integration.swift -o /tmp/heymate-phone-emulator-qa
cd firebase
npx firebase-tools@15.34.2 emulators:exec --project demo-heymate-accounts \
  --only auth,firestore /tmp/heymate-phone-emulator-qa
```

2026-11-21 validation: Google sign-in and pasted-code pairing worked on a physical iPhone. A device UI test tapped **Check unread mail** and verified Emily’s reply from the Mac worker using the live Gmail connection. The signed Mac build used `build_and_run.sh --verify`. The emulator smoke test separately verified queued delivery, replay and tamper rejection, competing claims, and cleanup.

## Native account gate

`CompanionAppDelegate` creates the companion lazily and starts it only after account access is granted. Voice, hotkeys, the notch, browser/local bridges, routines, provider setup, model downloads, app usage events and updater startup all wait behind this gate. Settings and app deep links also check it. Completing or skipping the old welcome tour cannot bypass it. Closing the account window quits the app; reopening resumes the saved session.

Existing installations must verify an account on their first launch of this version. Local chats, settings, existing provider sign-ins and macOS permission grants are not migrated or erased by account creation. Account authentication remains separate from ChatGPT/Claude/API sign-in. Account switching does not partition existing local chats or provider credentials; this is a local Mac app, not a multi-tenant data vault.

The current signup/sign-in flow is one Google button, using macOS `ASWebAuthenticationSession`, PKCE (S256), a random state, and the registered Apple OAuth client. Only basic OpenID identity scopes are requested; no Gmail/Drive/Calendar access. Google supplies the name and email. The Google ID token is exchanged through Firebase `accounts:signInWithIdp`, followed by a server account lookup. Both client and model require server-confirmed email verification before unlocking. The OAuth code/verifier and Google ID token stay in memory during the exchange; HeyMate persists only its own Firebase session. No password, verification email, subscription toggle or analytics prompt appears during signup. Legacy password/verification REST methods remain for compatibility and tests, but are absent from the new UI.

Passwords are never persisted by HeyMate. Refresh/ID tokens, display name, email, UID, server verification time and pending email preference are stored in a dedicated Keychain item with `AfterFirstUnlockThisDeviceOnly` accessibility. Token rotation is persisted. Requests use an ephemeral URLSession, no cookies/cache, no redirects and no raw provider-response logging. Keychain failures fail closed.

At each launch, the app attempts an online refresh and server lookup. A transport outage allows a previously server-verified Keychain session for at most seven days since its last successful verification, including an in-process expiry timer. Unverified sessions have no grace. Explicit invalid/disabled/deleted-session errors relock immediately, even if a cached verification is recent. A running app exits when its account access is withdrawn; detached runner work follows the existing survival contract. Sign-out first checks the app's existing in-flight-work termination guards, then clears this Mac's session and quits. It does not delete the cloud account or sign out other Macs.

## Independent choices

New accounts offer two separate optional, unchecked choices:

- **Share usage analytics:** existing local PostHog preference and random install ID. Existing opt-in is preserved; account email/UID are never attached to PostHog. Sign-in does not enable analytics.
- **Email me about HeyMate releases:** a per-account Firestore subscription preference, initially false. Existing sign-in loads cloud preference rather than overwriting it with a fresh form's unchecked default. Explicit changes are saved to Keychain before network submission and retried after refresh/restart. Offline/failed sync is visible in Privacy & Data.

Firestore stores only `releaseEmails`, `consentVersion: 1`, and a server-written `updatedAt` timestamp in `accountPreferences/{Firebase UID}`. Auth retains the account email. Rules require matching authenticated UID and Firebase-issued `email_verified == true`. Client listing/deletion, cross-account access, extra fields and forged verification/admin fields are denied. Account access does not depend on agreeing to either optional choice or on preference-sync availability.

**Release-mail delivery is not integrated.** No marketing email, campaign, sender, SMTP service, or contact export is configured. Firebase verification/password-reset messages are transactional authentication mail. Do not advertise automatic release notifications until an independently reviewed delivery/unsubscribe flow exists.

## Validation and release hold

- `bash heymate/scripts/test_accounts.sh` executes account lifecycle and Auth/Firestore transport unit tests against production sources in an isolated Swift package. It never reads the real Keychain, launches an app GUI or sends production traffic. The tests also belong to the normal Xcode test target.
- `cd firebase && npm install && npm test` runs emulator-only verification and consent-rule integration tests. Requires Node and Java 21+. Tests enforce local emulator hosts and a `demo-` project; no real inbox or production user is created.
- `heymate/scripts/typecheck.sh --tests` checks the app and hosted-test compilation without installing an unsigned app.
- Any local install must use `heymate/script/build_and_run.sh --verify`, with the installed certificate and compatible requirements. Set `HEYMATE_NODE_BINARY` to an official self-contained Node binary if the shell selects Homebrew Node.

No commit, push, app release, DMG publication, website deployment or release-email send is authorized by this implementation. Before releasing, manually exercise a real inbox signup/verification/reset and restart on the signed app; review the public privacy policy/account-support/deletion process. Emulator OOB verification does not establish production email delivery.

2026-10-31 validation: 13 Swift tests executed against the production account/client sources in an isolated Swift package; 10 Firebase emulator checks passed. Full app and test compilation passed. The signed local `--verify` install passed all nested-signature/compatible-requirement checks and launched `/Applications/HeyMate.app`. Account window and Cmd-comma Settings both showed the gate before sign-in; the locked process had no TCP listeners. Production probes with a deliberately invalid token returned Auth `INVALID_ID_TOKEN`, and an anonymous Firestore read returned `PERMISSION_DENIED`. These probes created no production account or mail. Firestore consent rules were applied through Umar's Firebase console on Spark; no app/website release was performed.

Official references: [Auth REST API](https://firebase.google.com/docs/reference/rest/auth), [Firestore rules conditions](https://firebase.google.com/docs/firestore/security/rules-conditions), [Auth Emulator](https://firebase.google.com/docs/emulator-suite/connect_auth).

## 2026-10-31: verification email delivered to Gmail spam

The user reported a real verification message in Gmail spam. Gmail's displayed reason concerned similarity to previously identified spam. This confirms delivery to that mailbox, not inbox placement or completion of the verification action. No verification link/action token is recorded here. No additional messages were sent during this investigation.

Umar's Firebase console showed sender name unset, the default Firebase sender domain, subject `Verify your email for %APP_NAME%`, and a locked verification-message body. Project display name is already HeyMate; General settings currently expose no Public-facing name field. Firebase documents that the Public-facing name determines `%APP_NAME%`, so changing the project ID or guessing at that substitution is not appropriate.

Attempted reversible branding: sender name `HeyMate`, subject `Verify your email for HeyMate`. Firebase rejected Save and displayed: **“Email template updates are currently unavailable for this project. For assistance with template changes, contact Firebase Support.”** Rechecking the template confirmed the original values remain. No branding correction was successfully applied.

Custom SMTP is disabled and its sender/host/credentials fields are empty. There is no configured authenticated SMTP sender to reuse in this project. The application's existing verification screen already instructs users to check inbox and spam and offers resend/recheck; no app code, account-gate behavior or analytics/email consent changed. Google sign-in was inspected without enabling or saving it. No DNS, billing or release settings changed.

Immediate user action: mark the known requested verification message “Not spam” in Gmail, use its verification link, then select “I've verified my email” in HeyMate. This is a per-mailbox correction, not a guarantee for other recipients. Do not repeatedly resend while diagnosing deliverability.

Minimal support request, prepared but **not sent**:

> Project: heymate-a4aee (HeyMate), Spark plan. Authentication → Templates → Email address verification rejects a sender-name/subject-only update with “Email template updates are currently unavailable for this project.” Requested sender name: HeyMate. Requested subject: Verify your email for HeyMate. Verification message body and action URL were not changed. Please enable supported template customization and advise how to set the public-facing app name used by %APP_NAME% without enabling another sign-in provider.

[Firebase's linked template support page](https://firebase.google.com/support/troubleshooter/auth/email/help). Do not include a real verification URL/token or user mailbox data in the request.

For a custom sender, first identify an owned domain and any existing sending provider. Firebase's native custom-domain flow supplies TXT/CNAME ownership/authentication records, then requires “Apply Custom Domain” after verification. Custom SMTP instead requires sender address, SMTP host/port/security mode and server-side credentials in Firebase console; credentials must never enter the app/repository. Neither branding nor domain authentication guarantees inbox delivery, and the available evidence does not establish that SPF/DKIM failure caused this spam placement.

References: [template fields and public-facing name](https://support.google.com/firebase/answer/7000714?hl=en), [custom sender-domain setup](https://firebase.google.com/docs/auth/email-custom-domain).

## 2026-10-31 follow-up: custom Firebase sender activated

After the user confirmed ownership of `umarsiddiqui.com.np` and explicitly authorized setup, Firebase's native custom email-domain wizard accepted `auth.umarsiddiqui.com.np`. No SMTP provider, mailbox subscription, paid service or billing upgrade was needed. DNS is authoritative at Vercel (`ns1.vercel-dns.com`, `ns2.vercel-dns.com`), not Cloudflare. Umar's signed-in Vercel account had the existing domain and editable DNS records.

Added exactly the four records provided by Firebase, each with TTL 60 seconds:

| Relative Vercel name | Type | Exact value |
| --- | --- | --- |
| `auth` | TXT | `v=spf1 include:_spf.firebasemail.com ~all` |
| `auth` | TXT | `firebase=heymate-a4aee` |
| `firebase1._domainkey.auth` | CNAME | `mail-auth-umarsiddiqui-com-np.dkim1._domainkey.firebasemail.com.` |
| `firebase2._domainkey.auth` | CNAME | `mail-auth-umarsiddiqui-com-np.dkim2._domainkey.firebasemail.com.` |

Vercel confirmed each creation. The root ALIAS, wildcard ALIAS and existing CAA records were preserved; root MX/TXT remained absent. Vercel warned that specific DKIM records override wildcard matching within `auth` and `*.auth`; this was accepted for the explicitly authorized dedicated authentication subdomain. No root website or `www` configuration was edited.

Both authoritative nameservers and public resolver `1.1.1.1` returned both TXT records and both exact DKIM CNAME targets. Firebase displayed **Verification complete**. “Apply custom domain” then succeeded: the verification template's persisted From address is now **`noreply@auth.umarsiddiqui.com.np`**. The hosted Firebase action URL was preserved so verification links continue to use the existing handler. Custom SMTP remains unnecessary and disabled.

Sender-name `HeyMate` and subject `Verify your email for HeyMate` were retried after domain activation. Firebase again rejected the template-only save with **“Email template updates are currently unavailable for this project.”** The activated From domain survived; display name/subject/body substitution remain unchanged and still need the prepared Firebase support request. Domain authentication succeeded independently of this branding restriction.

No test email or support message was sent, no additional sign-in provider was enabled, and no app/website release or deployment was performed. SPF/DKIM DNS configuration and Firebase activation are verified; a new message's headers and inbox placement have not been tested. No claim is made that DNS authentication alone prevents spam placement.

Console references: [Firebase email templates](https://console.firebase.google.com/u/0/project/heymate-a4aee/authentication/emails), [Vercel domain DNS](https://vercel.com/umarsiddiquis-projects/~/domains/umarsiddiqui.com.np).

## Account design previews

Debug builds support isolated PNG rendering through the existing appearance renderer:

```bash
/Applications/HeyMate.app/Contents/MacOS/HeyMate \
  --appearance-render /absolute/path/signup.png --appearance-account signup
```

Mode: `signup` (the same Google screen serves signup and sign-in). Run the standard signed `script/build_and_run.sh --verify` install first. Rendering uses dummy account data, an in-memory session store and no Firebase network configuration. It does not restore or change the real account, send email, or start app services. Rendering does not change analytics or release-email preferences. These snapshots check native layout, not mail-client delivery or interactive authentication.

Custom verification email designs live in `../../firebase/email-templates/`; they are not connected to managed Firebase delivery.


## 2026-10-31: Google signup supersedes custom mail delivery

The user requested name/email only, then chose Google sign-in instead of Resend setup. Google was enabled in Firebase; public-facing project name is HeyMate and support uses the existing project owner. Firebase automatically created the OAuth clients. Public Apple client ID and reversed callback scheme are configured in `Info.plist`, matched to `com.heymate.app`. Google’s official SwiftUI button is pinned to 9.0.0. Its authentication/token-store APIs are not used: the SDK token store would require a provisioning profile for a data-protection Keychain group, so the added entitlement was removed and the existing signing/Keychain setup was preserved. System browser authentication uses authorization-code PKCE, state/callback checks, HTTPS token exchange with redirects disabled, and Firebase server validation.

Resend signup was not completed, no API key/server was provisioned, and no billing upgrade was performed. The earlier email HTML is a design artifact, unused by Google signup. Existing Firebase email sender DNS remains intact for legacy mail. Existing analytics choices and release subscriptions are preserved; new release preferences remain false. Google name is stored only in Firebase's profile and the dedicated account Keychain session, not connected to analytics identity.

Validation includes 22 isolated production account/client/OAuth Swift tests, including cancellation, unverified identity rejection, failed persistence, consent preservation, and encoded Google credential exchange. Live Google UI verification is recorded separately; mock tests do not prove OAuth consent or callback behavior.

Signed canonical install passed `build_and_run.sh --verify` after the Google update. Native Google-screen PNG rendered and inspected. Existing entitlements/signing identity were preserved. The first real Google browser-consent/callback exchange remains untested; the existing verified session was not signed out for QA.


## 2026-10-31: Live Google sign-in smoke test passed

With the user's explicit approval, used the installed app's Sign out & quit action and reopened only `/Applications/HeyMate.app`. The account gate displayed Sign in with Google. Google consent showed the existing account and only name/profile picture and email access; no Gmail access was requested. Continuing returned to HeyMate, closed the account gate and restored the ready notch. Privacy & Data then displayed Verified email for the same account.

The release-email checkbox and existing analytics preference remained as they were before sign-out. This validates this existing account's consent/callback, Firebase verification and account-gate unlock in the canonical installed app. It does not establish fresh-account creation, every provider error path, permission grants, mail delivery or a signed release artifact. No password was entered, no provider scopes were expanded beyond identity, and no cloud configuration, signing, TCC, commit or publication changes were made.
