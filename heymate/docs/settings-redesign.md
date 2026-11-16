# Settings redesign

Status: implemented on this branch. This file is the audit that came before
the code, plus the information architecture (IA) the code follows.

## 1. Where settings live today

| Surface | File | Reached from |
| --- | --- | --- |
| Settings, five tabs (General, Accounts, Notch, Privacy, Advanced) | `DesktopSettingsView.swift`, `DesktopSettingsAccountsTab.swift` | Desktop window sidebar › Settings; the notch gear; Cmd-, (`Settings` scene in `HeyMateApp.swift`) |
| Notch tab content | `DesktopSupportingViews.swift` › `DesktopNotchView` | Settings › Notch, and `heymate://open/notch` |
| Privacy tab content | `DesktopSupportingViews.swift` › `DesktopPrivacyView` (+ erase card injected via `AnyView`) | Settings › Privacy, and `heymate://open/privacy` |
| Brain, model, voice, sign-in controls | `AISettingsComponents.swift` | Embedded by Accounts and Advanced |
| One-column notch settings | `AISettingsView.swift` | **Nothing.** No call site instantiates it. Dead code. |
| Save chats toggle, delete saved chats | `DesktopSupportingViews.swift` › `DesktopMemoryView` | Mate sheet › "Everything HeyMate remembers" |
| Per-mate settings (profile, brain, permissions, proactive, notifications, memory, files, apps, limits) | `MateSettingsSheet.swift` + `MateSettings*Pane.swift` | Mate rail, and deep links. See section 9. |

## 2. Inventory

Every control in the window today. "Key" is the persisted UserDefaults key,
which stays unchanged.

### General tab
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Talk shortcut | menu picker | `talkShortcutOption` |
| Chat shortcut | menu picker | `chatShortcutOption` |
| Dictate shortcut | menu picker | `dictateShortcutOption` |
| Region select shortcut | menu picker | `spatialSelectShortcutOption` |
| Double-tap Text on/off + key | switch + menu | `textDoubleTapEnabled`, `textDoubleTapShortcut` |
| Double-tap Hands-free on/off + key | switch + menu | `handsFreeDoubleTapEnabled`, `handsFreeDoubleTapShortcut` |
| Dictation mode Literal/Smart | segmented | `CompanionManager.dictationUsesSmartMode` |
| Silent mode | switch | `CompanionManager.isSilentModeEnabled` |
| Interaction sounds | switch | `CompanionManager.isUISoundEnabled` |
| Focused window context | switch | `CompanionManager.talkUsesFocusedWindowContext` |
| Cursor companion | switch | `CompanionManager.setCursorCompanionEnabled` |
| Replay onboarding | button | `replayOnboarding()` |
| Microphone input device | menu | `AudioInputDeviceCatalog.selectedDeviceUID` |
| Mac voice | menu | `SpeechVoiceCatalog.selectedSystemVoiceID` |
| Accent color | swatches | `CompanionManager.themeColorPreferenceKey` |
| Show in Dock | switch | `showsInDock` |
| Without a notch | segmented | `noNotchPlacement` |
| Launch at login | switch | `launchesAtLogin` |
| Show in screen recordings | switch | `appearsInScreenRecordings` |
| Check for updates / check automatically / version | button + switch | Sparkle via `AppUpdateController` |
| Support links (bug, feature, email, permissions, issues…) | link buttons | `SupportLinks.destinations` |

### Accounts tab
| Control | Type | Source |
| --- | --- | --- |
| Which AI do you pay for (Claude / ChatGPT / On this Mac) | radio rows + Sign in / Set up / Switch account | `setSelectedBrain`, `heyMateBeginSubscriptionSignIn` notification |
| Check again | button | `refreshHeadlessExecutorReadiness()` |
| Model (Claude or ChatGPT) | menu | `setSelectedClaudeModel` / `setSelectedCodexModel` |
| On this Mac status | text | `OnDeviceLanguageAvailability` |
| Connected apps | link to Apps | `heyMateDesktopSelectSection` |

### Notch tab
| Control | Type | Key |
| --- | --- | --- |
| Micro-apps (timer, now playing, battery, calendar, clipboard…) | switch per tile | `NotchActivityCenter` |
| Open the card on hover | switch | `notchHoverOpensCard` |
| Timer start/cancel | field + buttons | `NotchTimerStore` |
| Clipboard history, Clear history | list + destructive | `ClipboardHistoryStore` |
| Next event, Join | readout | `CalendarPeekMonitor` |

### Privacy tab
| Control | Type | Key |
| --- | --- | --- |
| Never capture these apps (add / remove) | list + field | `excludedAppBundleIds` |
| What leaves this Mac | static facts | — |
| Erase HeyMate data | destructive + confirm | `LocalDataErase` |

### Advanced tab
| Control | Type | Key |
| --- | --- | --- |
| Other AI engines (OpenCode, Custom API) | tile grid | `setSelectedBrain` |
| Claude/ChatGPT effort | menu | `setSelectedClaudeEffort` / `setSelectedCodexReasoningEffort` |
| Voice chat start/stop | link button | `toggleSubscriptionVoiceChat()` |
| OpenCode models (search, list), OpenCode address | list + field | `openCodeServerURLString`, `selectOpenCodeModel` |
| Custom API server / model / key | fields | `CustomAPIConfiguration` |
| Agent jobs sign in / sign out, project folder | status + links | `HeadlessExecutorSignIn` |
| Keep AI apps up to date, Update now | switch + button | `keepsSubscriptionCLIsUpdated` |
| Listen provider, Speak provider | segmented | `setSelectedListenProvider` / `setSelectedSpeakProvider` |
| On-device voice download/remove | row + confirm | `OnDeviceVoiceModelStore` |
| ElevenLabs key save/remove | secure field | `ElevenLabsCredentials` |
| ElevenLabs voice (+ custom ID) | menu + field | `SpeechVoiceCatalog.selectedElevenLabsVoiceID` |
| Composio key save/replace/remove | secure field + confirm | `ConnectorSecretStore` |
| Google (gogcli) status | readout | `HeyMateGogCLIStatusResolver` |
| Let HeyMate use this Mac | switch | `ComputerUseCoordinator.isEnabled` |
| Background app control (Cua driver install/update) | status + button | `CuaDriverSetup` |
| Behavior contract edit / reveal / reset | sheet | `BehaviorContract` |

## 3. Problems found

**Information architecture**
1. One topic, three tabs. Voice is split: *Mac voice* under General › Voice, *Listen/Speak providers* and the *ElevenLabs voice* under Advanced › Listen & speak, and the *Microphone* under General. The Voice card's footnote has to send people to "Advanced › Listen & speak".
2. Model and effort are split: the model under Accounts, its effort under Advanced, with a footnote pointing across tabs.
3. "Advanced" is a junk drawer of nine unrelated cards (engines, effort, agent sign-in, CLI updates, voice providers, Composio, Google, computer control, behavior contract). Its name says nothing about what is inside, which is why the Apps page has to say "Paste it once in Settings → Advanced".
4. General mixes four jobs: keyboard shortcuts, talk behavior, audio devices, app presence, plus updates/support. Eight cards, the longest page.
5. *Show in screen recordings* is a privacy decision but sits under "System presence".
6. *Save chats on this Mac* is a privacy/data switch that only exists on the Memory page, which is not in the sidebar.
7. Five tabs in a capsule tab bar do not scale and do not support search; there is no way to find "microphone" without guessing the tab.

**Duplicates and dead options**
8. `AISettingsView` (the notch column) is never instantiated. It, its private header, and `VoiceProviderSettingsContent.showsInteractionSoundsToggle` (a second "Clicks" switch for the same `isUISoundEnabled`) are dead.
9. Two accent pickers: `ThemeColorPicker` (AppTheme.swift, used by onboarding) and a hand-rolled swatch row in General with a hard-coded `Color.white` ring that is invisible in light mode.
10. Three different "card" scaffolds for the same thing: `DesktopCard`, `AISettingsCard`, and ad-hoc `VStack`s with `Divider().opacity(0.25)`.

**Controls and labels**
11. Mixed control vocabulary: native `.switch` toggles, native `.segmented` and `.menu` pickers (Apple chrome), custom capsule menus (`AISettingsMenuLabel`), custom segment buttons that prefix a "✓" into the label, link-style buttons (`NotchLinkButton`), and three button families for the same weight of action.
12. "Clear" vs "Save" on the custom API key button changes meaning with field contents; empty-field "Clear" deletes the saved key with no confirmation.
13. "Clicks" vs "Interaction sounds" — two names for one setting.
14. The Listen/Speak pickers print "Selected: X" under a control that already shows the selection.
15. The ElevenLabs key "Remove" and the custom API key clear have no confirmation, while the Composio key removal does.
16. *Open the card on hover* binds to a static property through a non-observed `Binding`, so the switch can show a stale state after it is flipped.
17. Shortcut pickers accept the same combo for two roles (documented "whichever tap started first wins") with no warning in the UI.
18. No way back to defaults for shortcuts.
19. Labels with CLI vocabulary leak into everyday copy ("`opencode serve`", "gogcli") without being framed as setup steps.

**Design system**
20. Hard-coded values: `Color.white.opacity(…)` swatch ring, `.system(size: 12, design: .monospaced)` for bundle ids, `.custom("Avenir Next", size: 14)` in the contract editor, `frame(width: 180)` and `maxWidth: 260` picker widths, raw paddings.
21. Native rounded-border text fields (`.textFieldStyle(.roundedBorder)`) next to HeyMate field chrome.

**Accessibility and states**
22. Swatches have no selected state for VoiceOver; tab buttons have labels but the radio rows in Accounts are buttons with a hidden radio mark and no value.
23. No keyboard focus ring on custom controls; many rows are tap targets below 24 pt.
24. Loading states are inconsistent (spinner replaces button in some places, text in others); error text sometimes amber, sometimes red for the same severity.

## 4. New information architecture

A section rail (sidebar) with search replaces the tab bar. Inside the desktop
window the rail *is* the window sidebar while Settings is open (with "Back to
chat" and "Apps" above it), so there is never a sidebar beside a sidebar. The
Cmd-, Settings window shows the same rail on its own.

```
HeyMate
  General             Appearance · Startup & presence · Updates · Help
  Shortcuts           Hold to talk · Double-tap · Restore defaults
  Talk & Voice        Talking · Microphone · Listening · Speaking
  Notch               Micro-apps · Behavior · In the notch now
Intelligence
  AI & Accounts       Your AI · Model · Voice chat · Other engines · Helper apps
  Agents & Control    Agent jobs · Computer control · Honesty & safety rules
  Connections         Connected apps · Composio · Google
Privacy
  Privacy & Data      Screen capture · Chats & memory · Phone access · What leaves this Mac · Danger zone
```

Moves, by item:

| Item | From | To |
| --- | --- | --- |
| Push-to-talk + double-tap shortcuts | General | **Shortcuts** (new) |
| Dictation mode, Silent mode, Focused window, Interaction sounds | General › Behavior | **Talk & Voice › Talking** |
| Microphone | General | **Talk & Voice › Microphone** |
| Listen provider | Advanced | **Talk & Voice › Listening** |
| Speak provider, Mac voice, on-device voice, ElevenLabs key + voice | General + Advanced | **Talk & Voice › Speaking** |
| Cursor companion | General › Behavior | **General › Startup & presence** |
| Replay onboarding | General › Behavior | **General › Help** |
| Show in screen recordings | General › System presence | **Privacy & Data › Screen capture** |
| Model + effort | Accounts + Advanced | **AI & Accounts › Model** (together) |
| Voice chat | Advanced | **AI & Accounts › Voice chat** |
| OpenCode / Custom API | Advanced | **AI & Accounts › Other engines** (setup shown only when chosen) |
| Keep AI apps updated | Advanced | **AI & Accounts › Helper apps** |
| Agent sign-in + project folder | Advanced | **Agents & Control › Agent jobs** |
| Computer control, Cua driver | Advanced | **Agents & Control › Computer control** |
| Behavior contract | Advanced | **Agents & Control › Honesty & safety rules** |
| Connected apps link | Accounts | **Connections** |
| Composio key, Google | Advanced | **Connections** |
| Save chats on this Mac | Memory page only | **Privacy & Data › Chats & memory** (Memory page keeps its contextual copy; both bind the same property) |
| Erase HeyMate data | Privacy | **Privacy & Data › Danger zone** |

Naming: section names are nouns a person would type into search; row titles
are the thing being set, not the mechanism ("Interaction sounds", never
"Clicks"; "Helper apps" with Claude/Codex/OpenCode named in the help line).
"AI & Accounts" keeps the word existing in-app copy uses ("Sign in from
Settings → AI & Accounts"). Buttons keep HeyMate's sentence case; a trailing
ellipsis marks buttons that open a dialog or sheet ("Erase…", "Edit…").

### Deep-link contract

`desktopSettingsSelectedTab` keeps its key and existing raw values
`general`, `accounts`, `notch`, `privacy`. New raw values: `shortcuts`,
`voice`, `agents`, `connections`. The removed `advanced` value still
resolves (to `connections`, where the only in-app writer — the Apps page's
Composio prompt — now points directly).

## 5. Component kit

All in `SettingsComponents.swift`, on DS tokens only:

- `SettingsPage` — title, subtitle, scrolling column at the settings measure, scroll-to-result.
- `SettingsSection` — sentence-case header, one matte card, optional footer.
- `SettingsRow` — title, help text, optional icon, trailing accessory. Base for every row.
- `SettingsToggleRow` — row + `DSSwitchToggleStyle` (matte track, keyboard focusable, VoiceOver toggle trait).
- `SettingsPickerRow` + `DSMenuPicker` — HeyMate menu button with checkmarks.
- `DSSegmentedControl` — capsule segmented control with per-segment disabled reasons.
- `SettingsDestructiveRow` — red action that always confirms.
- `SettingsStatusBadge` — positive / attention / critical / neutral / progress.
- `SettingsInlineHelp` and `SettingsNotice` — help text and tinted callouts with an optional action.
- `SettingsDivider`, `settingsFieldChrome()`, `SettingsSecretKeyRow`.

New tokens in `DesignSystem.swift`: `DS.SettingsLayout` metrics (rail width,
content measure, row insets, row min height, control widths, switch and radio
sizes), `DS.Colors.switchTrackOn/Off`, `switchKnobOn/Off`, `selectionFill`,
`focusRing`, `revealHighlight`, `DS.Fonts.mono`, `DS.Fonts.editor`.

Also in the kit: `SettingsChoiceRow` + `SettingsRadioMark` (pick-one lists such
as the AI engine), `SettingsEmptyRow`, `SettingsRefreshButton`.

## 6. Behaviors added

- Search across every setting (title, help text, synonyms). Results list in
  the rail; choosing one opens the section, scrolls to the row, and flashes it.
  Return picks the first result; Esc clears.
- Shortcut conflict warning when two hold-to-talk roles share a combo, and
  *Restore defaults* for shortcuts.
- Confirmation for every removal of a stored key (ElevenLabs, custom API,
  Composio) and for erase/sign-out; destructive styling on all of them.
- VoiceOver: switches are exposed as native toggles (label = row title, hint =
  help text); segmented controls, swatches, the rail, and radio rows report
  selection; section titles are headers.
- Privacy › Never capture: *Choose app…* picks an app instead of typing its
  bundle id; typed ids are checked and duplicates are refused.
- *Open the card on hover* now binds through `@AppStorage` (same key and
  default), fixing the stale switch.
- `AISettingsView.swift` (dead) is deleted; the duplicate accent picker now
  shares `SettingsAccentSwatches` with onboarding.

## 7. Verification

- Unit tests: `DesktopSettingsTabsTests` (deep-link contract, legacy
  `advanced` alias, rail grouping) and `SettingsCatalogTests` (search ranking,
  synonyms, diacritics, shortcut conflicts, bundle-id check). Neither touches
  UserDefaults.
- Visual check: each section in light and dark via `screencapture` on a Mac
  (not possible from the Linux container this branch was written in).

## 8. Polish pass: calmer, more premium

- **Blur:** the section rail uses AppKit's behind-window sidebar blur
  (`DSVisualEffectBackground`) under a matte tint (`DS.Colors.chromeTint`).
  When a page's title scrolls away it condenses into a frosted bar
  (`.ultraThinMaterial` + `DS.Colors.condensedBarTint`) that content slides under.
- **Motion:** pages cross-fade with a slight lift (`DS.Animation.settingsPage`,
  critically damped); the rail's selection pill slides between items
  (`matchedGeometryEffect`); expanders ease open (`DS.Animation.settingsDisclosure`).
  All of it drops to plain fades under Reduce Motion
  (`DS.Animation.reducedMotionFade`; the rail pill fades rather than slides).
- **Rhythm:** 52pt rows, 18pt insets, 36pt between sections, a 640pt column,
  16pt card corners with a hairline and a barely-there shadow.
- **Less clutter:** decorative icons removed from Help and fact rows; most help
  text cut to one line; secondary detail folds behind `SettingsDisclosureRow`
  (Always true rules, What leaves this Mac, Other engines — the last opens
  itself when one of those engines is in use).

## 9. Agent settings

Per-agent settings use the same kit and the same layout as the app window: a
section rail with search (Cmd-F; Return opens the first result, Esc clears)
beside one section at a time. `MateSettingsSheet.swift` is the shell; each
section is its own `MateSettings*Pane.swift`. Every control saves as it
changes (text after typing settles); destructive actions confirm. Nothing
spends a model call except Proactive › Check now and Profile › Draft habits.
The default agent (`conductsOthers`) hides Duplicate, Archive, Delete and the
folder rows. Search index and anchors: `MateSettingsCatalog.swift`.

New per-agent values live in `mate-agent-settings.json` under
`HeyMateDataDirectory` (`MateAgentSettingsStore`), keyed by agent id, so the
Mate record keeps the shape the previous release reads. Brain fields stay on
the Mate record, where they already were.

Deep links (`MateSettingsRouter`): the approval card's "Rules…" opens
Permissions, a check-in proposal's gear opens Proactive, the live browser
panel's gear opens Files & Browser.

### Profile
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Picture | button › character editor | `Mate.faceAssetName` |
| Name, job, personality | fields | `Mate.name`, `Mate.job`, `Mate.soul` |
| How it works, Asks you before | lists | AGENTS.md › Standing preferences |
| Duplicate | button | `duplicateMate(id:)` |
| Archive / Unarchive | button + confirm | `Mate.archived` |
| Delete | destructive + confirm | `deleteMate(id:)` |

### Brain
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Brain (Same as HeyMate or a signed-in provider) | menu | `Mate.brainRawValue` |
| Model (that provider's models only) | menu | `Mate.modelID` |
| Effort (levels the model supports) | menu | `Mate.effortRawValue` |
| Backup brain | menu | `Mate.backupBrainRawValue` |

Sent on every turn, routine, check-in and continuation as the per-chat brain
(`resolvedSessionBrain` › runtime `resolveSessionBrain`).

### Permissions
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Approval mode: Same as HeyMate / Always ask | segmented | `mate-agent-settings.json` › `approval` (global `approvalMode` unchanged) |
| Allow / ask / deny rules: add, edit, delete | list + form | `mate-approval-rules.json` |
| Always asks (the floor) | readout | `ApprovalFloor`, `MateApprovalRuleMatcher.floorAsks` |
| What it can reach | readout | folder, integrations, browser, skills |

"Always ask" can only make an agent stricter: Full access does not apply and
allow rules are set aside; ask and deny rules still apply
(`MatePermissionResolver`).

### Proactive
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Propose work on its own | switch | `mate-heartbeats.json` › `enabledOverride` |
| Last check-in, Check now | readout + button | `mate-heartbeats.json` |
| Allow check-ins for every agent | switch | `mate-heartbeats.json` › `globalEnabled` |
| Quiet hours on/off, from, until | switch + menus | `quietHours.enabled`, `startMinute`, `endMinute` (default 21:00 to 07:00) |
| Offers to help when | menu + field | `MateWakeStore` |
| Routines (add by phrase, edit rows) | field + rows | `MateRoutineStore` |
| Standing orders (HeyMate only) | switches | standing-orders Markdown files |

Quiet hours stop check-ins and wake offers; a routine still runs and its
notice is delivered when quiet hours end.

### Notifications
| Control | Type | Key |
| --- | --- | --- |
| Proposals | switch | `notifications.proposals` |
| Finished work | switch | `notifications.finishedWork` |
| Needs your input | switch | `notifications.needsInput` |
| Failed routine | switch | `notifications.failedRoutine` |

All default on. Notifications only go out while HeyMate is not in front, so
finished work never notifies for a chat you are watching
(`MateNotificationGate`, `AgentUserNotifier`).

### Memory
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Notes (dated rows: add, edit, remove) | list | AGENTS.md › Notes, mirrored to `Mate.memoryNote` |
| Note (agents without a folder) | field | `Mate.memoryNote` |
| Standing preferences (add, edit, remove) | list | AGENTS.md › Standing preferences |
| Everything HeyMate remembers | link | Memory page |

### Files & Browser
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Folder: Reveal, Change… | buttons | `Mate.folderPath` |
| Open Files | link | Files view |
| File history size, Clear history… | destructive + confirm | `mate-files/<folder>/versions` |
| Keep its sign-ins | switch | `persistentBrowserMateIDs` |
| Sign out of everything… | destructive + confirm | moves the agent's CuaDriver profile to the Trash |
| Show the live view open | switch | `browserPanelStartsOpen` |

### Apps & Skills
| Control | Type | Key / source of truth |
| --- | --- | --- |
| Integrations | switches | `Mate.connectorOverrides` (HeyMate: chat connector defaults) |
| Skills, Manage skills | readout + link | skills library |

### Limits
| Control | Type | Key |
| --- | --- | --- |
| Continuations per task | menu | `limits.maxContinuations` (default `MateAgentContinuation.maxContinuations`) |
| Routine time limit (routines without their own) | menu | `limits.routineMinutes` |
| Check-ins per day | menu | `limits.heartbeatsPerDay` (default 2) |
| Today: turns, check-ins, routine runs | readout | `activity` (counts only, this Mac) |

Tests: `MateAgentSettingsTests` (quiet hours, notification gate, stricter-only
approval, limits, counts, file compatibility, folder choice, rule edit and
reload) and `MateSettingsCatalogTests` (search, conductor visibility, note rows).

## 10. Phone access

Privacy & Data › Phone access (`SettingsPhoneAccessSection.swift`, search item
`phoneAccess`). Reach your mates from a phone browser on the same network.
Off by default.

| Control | Type | Key |
| --- | --- | --- |
| Reach your mates from your phone | switch | `phoneAccessEnabled` (UserDefaults, default off) |
| Address | readout | this Mac's private IPv4 + port 47821 |
| Pair a phone… | button → code + QR (5 min, single use, 5 tries then locked) | in memory only |
| Paired phones, Revoke | list + destructive | `phone-access.json` (hashes only) |
| Recent phone activity | last 5 of 50 | `phone-access.json` |

Behaviour: the listener lives in the app (`RemoteAccessController`,
`RemoteAccessServer`), not the agent runtime, because the Inbox is app state.
It is plain HTTP and the footer says so. Turning the switch off stops the
listener, ends every connection, voids the pairing code and unpairs every
phone. Phones idle for 30 days are forgotten. Rules and the fixed route list
are in `RemoteAccessCore.swift`, tested by `RemoteAccessCoreTests`.

## Verified build

The historical screenshots from this verification were removed on 2026-11-01
because they show outdated UI. Capture the current app before preparing new
documentation or marketing material; do not restore the retired images.
