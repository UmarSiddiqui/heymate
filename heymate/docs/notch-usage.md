# Coding usage notch

The normal notch shows usage rings for connected Codex, Claude Code and Cursor accounts. Hover/click opens the Usage card: reported percentages, reset times, and live **HeyMate-managed** agent work, including waiting-for-approval states. Home remains available for mates and approvals. External IDE/CLI session activity is not inferred from whether an app is running.

Each provider is off until Connect or its Settings → Notch switch is selected. The implementation reads only the default profile:

- Codex: `CODEX_HOME/auth.json`, falling back to `~/.codex/auth.json`; GET `https://chatgpt.com/backend-api/wham/usage`.
- Claude Code: `Claude Code-credentials` in Keychain; GET `https://api.anthropic.com/api/oauth/usage`. Only explicit Connect/Allow access can prompt; timer polls refuse interaction. Expired tokens require sign-in through Claude Code.
- Cursor: read-only `Library/Application Support/Cursor/User/globalStorage/state.vscdb`, including its current WAL; GET `https://cursor.com/api/usage-summary`. Reports Auto and API buckets separately, with the enterprise included-limit fallback.

Credentials are never logged, saved by HeyMate, refreshed, or sent to analytics. Requests refuse redirects. Only numeric usage windows and timestamps are cached. Poll every two minutes, retain the last good reading on transient failure, mark readings stale after five minutes or when reset passes, remove cached readings on authentication failure, and persist server rate-limit backoff. Provider endpoints can change; missing data is unavailable, never fabricated zero usage. This is deliberately not full Codenotch provider/profile parity.

Response mappings and session conventions are adapted from https://github.com/vinzdg/codenotch under MIT. `HeyMate/Codenotch-LICENSE.txt` ships with the app.

## Drag-only shelf

File drag into the notch shows a mate face with an open mouth. Successful drop briefly closes the mouth, then shows parked files. Click opens, drag exports a file URL, and the context menu reveals/removes a bookmark. AirDrop remains available after a drop. Originals are never moved or deleted. Existing shelf bookmarks survive this change and app exit. Dragging a file opens the shelf again; ordinary clicks/hover never select it. Closing or canceling returns to usage/home. Legacy micro-app preferences no longer start clipboard, camera, calendar or device monitors.
