# Contributing to HeyMate

Help someone learn a useful task in a desktop app or website, understand how they did it, and want to use HeyMate again. HeyMate currently runs on macOS. Small, reproducible improvements are more useful than a large new feature without a tested workflow.

## Choose a small change

Check [open issues](https://github.com/UmarSiddiqui/heymate/issues) and [pull requests](https://github.com/UmarSiddiqui/heymate/pulls) before starting. For a larger change, open an issue describing the user problem, the smallest proposed fix, and how you will verify it. For a small fix, a focused PR is welcome.

Three starter tasks, with clear boundaries:

1. **A walkthrough in another language.** Add one language's guidance phrases to `heymate/HeyMate/TalkContextPolicy.swift` with positive and negative examples in `TalkContextPolicyTests.swift`. The change should recognize requests such as “show me how” without making unrelated text-only questions capture the screen. Describe the language and examples in an issue first.
2. **An accessible install-command copy button.** Improve `website/js/main.js` so keyboard and screen-reader users hear whether copying succeeded or failed. Keep the command selectable when clipboard access is unavailable. Verify Enter, Space, denied clipboard access, and VoiceOver; keep the change limited to this interaction.
3. **A reproducible first walkthrough.** Document one small task in a free desktop app or website accessible on macOS, using a sample file you may share. Record the HeyMate version, provider/model, starting state, exact prompt, expected steps, observed mistakes, and whether the person could repeat it without help. Add a short guide under `docs/walkthroughs/`; label any recording edits or speed changes. No Swift experience needed.

These are starting points, not assigned issues. Check current work before claiming one. A useful bug report, documentation correction, or accessibility review is also a contribution.

## Build locally

Requires macOS, Xcode 26, and an internet connection for the first Swift package resolution.

```sh
git clone https://github.com/UmarSiddiqui/heymate.git
cd heymate
open heymate/HeyMate.xcodeproj
```

Select the `HeyMate` scheme and **My Mac**. Set your development team in Signing & Capabilities before running. macOS ties Accessibility and Screen Recording permission to the app's signing identity; replacing an installed build with a differently signed one can require granting permissions again.

For a compile check that uses scratch build output and does not re-sign the installed app:

```sh
./heymate/scripts/typecheck.sh
./heymate/scripts/typecheck.sh --tests
```

The second command **builds** test targets; it does not run the tests. Run relevant unit tests from Xcode, or use the `build-for-testing` and `test-without-building` commands in [PR build](.github/workflows/pr-build.yml). Use separate DerivedData when running command-line tests. Include the command and result in the PR.

For website-only work:

```sh
python3 -m http.server 8080 --directory website
```

Open `http://localhost:8080`. Check a narrow and a wide window, keyboard navigation, and reduced motion if your change affects layout or interaction. The site is static HTML, CSS, and JavaScript; no package install is needed.

## Find the right area

| Area | Entry point |
| --- | --- |
| Screen guidance | `CompanionPrompts.swift`, `CompanionManager+Guidance.swift`, `GuidedReplyParser.swift`, `TalkContextPolicy.swift` |
| Mates and routines | `MateProfile.swift`, `MateStore.swift`, `CompanionManager+Mates.swift`, `MateRoutineScheduler.swift` |
| Provider and agent execution | `MateAgentServeConversationClient.swift`, `agent-runtime/src/harness.mjs`, `HeadlessAgentLauncher.swift` |
| Local storage and privacy | `ChatHistoryStore.swift`, `MemoryRepository.swift`, `CaptureAudit.swift`, `HeyMateAnalytics.swift` |
| Website | `website/` |
| Video source | `marketing/demo-video/` |

Swift paths above live under `heymate/HeyMate/`. Tests live under `heymate/HeyMateTests/`.

## Make changes reviewable

- Describe the task that failed and the behavior after your change. Include the steps another person needs to reproduce it.
- Keep one PR focused on one problem. Add regression coverage when it protects meaningful behavior; do not add tests that only repeat implementation details.
- For UI changes, attach before/after screenshots or a short recording with sample data. Explain which provider and macOS version you tested.
- Keep prompts, audio, screenshots, account names, credentials, and private paths out of diagnostic events and public issue attachments. Never commit local secrets or user data.
- Preserve existing license notices. Name any reused project, its license, and the files brought in. Do not copy proprietary app code or assets.
- AI-assisted contributions are welcome. Review generated code, explain the change, and report checks actually run.

Changes to app code on `main` can publish a release automatically. Changes to the release workflow and `.github/scripts/` can also trigger release publishing. Website and Markdown-only changes do not publish an app build. Do not mark an unreleased change as shipped in the website changelog.

## Report a problem

Use the existing [bug, install, or feature forms](https://github.com/UmarSiddiqui/heymate/issues/new/choose). Include the app version, macOS and Mac model, provider/model, steps, expected result, and actual result. Crop or replace private screen content before attaching evidence.

For a sensitive report, email [umarsiddiqui3037+heymate@gmail.com](mailto:umarsiddiqui3037+heymate@gmail.com?subject=HeyMate) instead of posting publicly.

Contributions are under the [MIT license](LICENSE). Existing third-party notices remain in [THIRD_PARTY_NOTICES.md](heymate/THIRD_PARTY_NOTICES.md).
