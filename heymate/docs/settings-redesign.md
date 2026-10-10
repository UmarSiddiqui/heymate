# Settings redesign

Status: implemented on this branch. This file is the audit that came before
the code, plus the information architecture (IA) the code follows.

## 1. Where settings live today

| Surface | File | Reached from |
| --- | --- | --- |
| Settings, five tabs (General, Accounts, Notch, Privacy, Advanced) | `DesktopSettingsView.swift`, `DesktopSettingsAccountsTab.swift` | Desktop window sidebar › Settings; the notch gear; Cmd-, (`Settings` scene in `leanring_buddyApp.swift`) |
| Notch tab content | `DesktopSupportingViews.swift` › `DesktopNotchView` | Settings › Notch, and `heymate://open/notch` |
| Privacy tab content | `DesktopSupportingViews.swift` › `DesktopPrivacyView` (+ erase card injected via `AnyView`) | Settings › Privacy, and `heymate://open/privacy` |
| Brain, model, voice, sign-in controls | `AISettingsComponents.swift` | Embedded by Accounts and Advanced |
| One-column notch settings | `AISettingsView.swift` | **Nothing.** No call site instantiates it. Dead code. |
| Save chats toggle, delete saved chats | `DesktopSupportingViews.swift` › `DesktopMemoryView` | Mate sheet › "Everything HeyMate remembers" |
| Per-mate profile (name, job, soul, picture, note, routines) | `MateSettingsSheet.swift` | Mate rail. Per-object editing, not app settings: out of scope for the IA, kept as is. |

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
| Cursor companion | switch | `CompanionManager.setClickyCursorEnabled` |
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
| Micro-apps (shelf, timer, now playing, battery, calendar, clipboard…) | switch per tile | `NotchActivityCenter` |
| Open the card on hover | switch | `notchHoverOpensCard` |
| File shelf items, Clear shelf | list + destructive | `NotchShelfStore` |
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
  AI                  Your AI · Model · Voice chat · Other engines · Helper apps
  Agents & Control    Agent jobs · Computer control · Honesty & safety rules
  Connections         Connected apps · Composio · Google
Privacy
  Privacy & Data      Screen capture · Chats & memory · What leaves this Mac · Danger zone
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
| Model + effort | Accounts + Advanced | **AI › Model** (together) |
| Voice chat | Advanced | **AI › Voice chat** |
| OpenCode / Custom API | Advanced | **AI › Other engines** (disclosed only when chosen) |
| Keep AI apps updated | Advanced | **AI › Helper apps** |
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
- `SettingsDivider`, `settingsFieldChrome()`, `SettingsSecretField`.

New tokens in `DesignSystem.swift`: `DS.Settings` metrics (rail width, content
measure, row insets, row min height, control widths), `DS.Colors.switchTrackOn/Off`,
`switchKnob`, `selectionFill`, `focusRing`, `DS.Fonts.mono`, `DS.Fonts.editor`.

## 6. Behaviors added

- Search across every setting (title, help text, synonyms). Results list in
  the rail; choosing one opens the section, scrolls to the row, and flashes it.
  Return picks the first result; Esc clears.
- Shortcut conflict warning when two hold-to-talk roles share a combo, and
  *Restore defaults* for shortcuts.
- Confirmation for every removal of a stored key (ElevenLabs, custom API,
  Composio) and for erase/sign-out; destructive styling on all of them.
- VoiceOver: every row is one element with label, value, and hint; swatches
  report selection; status badges read their tone.
