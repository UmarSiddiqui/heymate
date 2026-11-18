# Troubleshooting HeyMate

Most problems are one of five things. Work down the list before filing an issue.

## The hotkey does nothing

HeyMate watches for holding ⌃⌥ through Accessibility.

1. Open System Settings → Privacy & Security → Accessibility.
2. Make sure HeyMate is listed and switched on. If it is on but still dead, switch it off and on again.
3. Quit and reopen HeyMate from `/Applications`. Copies running from the DMG or Downloads count as a different app to macOS.

## It cannot see my screen, or answers as if it cannot

Screen Recording is separate from Accessibility. Check System Settings → Privacy & Security → Screen Recording, then quit and reopen HeyMate, because macOS applies the grant on the next launch.

Password managers and System Settings are never captured. If you asked about one of those, that is expected.

## It cannot hear me

Check Microphone in the same Privacy & Security pane. HeyMate listens only while you hold the hotkey. If you chose ElevenLabs or the downloaded on-device voice, check that choice in Settings, since each has its own requirements. Apple Speech is the fallback.

## It says my AI is not signed in

HeyMate uses the Claude Code, Codex, or OpenCode you already have, or a Custom API endpoint. Run the tool once in Terminal (`claude`, `codex`, or `opencode`) and sign in there, then try again. HeyMate never asks for those passwords.

## macOS blocked it from opening

Official releases are signed with a Developer ID and notarized, so they should open normally. If macOS still refuses, you probably have an old or modified copy. Download the latest `HeyMate.dmg` from the [releases page](https://github.com/UmarSiddiqui/heymate/releases) and replace the app in `/Applications`.

## Permissions disappeared after an update

Permissions survive updates for signed releases. If they do not, HeyMate is probably running from a different location than before. Quit it, delete other copies, run the one in `/Applications`, and grant the permission again. HeyMate never resets your privacy settings on its own.

## What leaves my Mac

See the [privacy notes](https://sayheymate.com/privacy) and the [permissions page](https://sayheymate.com/permissions).

## Reporting a useful bug

A report we can act on has:

- The HeyMate version (the info button in the notch) and your macOS version and Mac model.
- Which brain you use: Claude Code, Codex, OpenCode, or a Custom API.
- Steps to reproduce, what you expected, and what happened.
- A screenshot or short recording, with anything private cropped out.

One problem per issue. Never paste API keys, tokens, or private screen content. If it should not be public, email umarsiddiqui3037+heymate@gmail.com instead.

[Open an issue](https://github.com/UmarSiddiqui/heymate/issues/new/choose)
