# Coding usage notch

Connected coding tools appear in a compact row of provider-logo rings. Three full logos fit beside the hardware notch; overflow uses a count badge. Open **Usage** for the horizontal overview, select one provider for quota windows/reset times and observed sessions, and use **All providers** to return. Home, voice, mates and approvals keep their existing navigation.

Settings → Notch keeps **connections** separate from **display**:

- **Always show idle usage rings** defaults on for existing users. Switch it off to hide persistent rings while keeping connections, polling and intentional Usage access.
- Each connected provider has a separate **Idle ring** checkbox.
- **Show remaining** defaults off. Percent text and arcs flip together; warning colors still judge spent quota. Counts never pretend to be remaining quota.
- **Weekly ring** defaults off and uses the inside band while no activity needs that space.
- **Provider order** offers remembered manual order (move buttons) or most remaining first. Count-only providers stay after providers with a known quota in remaining order.
- **Reduce usage motion** keeps rings and notch transitions still. macOS Reduce Motion always wins.

Existing Codex/Claude/Cursor connection IDs, sign-ins, custom sources and cached readings migrate in place. New providers are opt-in and do not become connected after upgrading.

## Supported readers

| Provider | Usage source and limits | External activity |
| --- | --- | --- |
| Codex | `CODEX_HOME/auth.json` or `~/.codex/auth.json`; ChatGPT usage endpoint | Recent default-profile rollout lifecycle events; heuristic freshness |
| Claude Code | `Claude Code-credentials` in Keychain; Anthropic OAuth usage | Fresh terminal session registry status, live/non-suspended process; unknown desktop transcript state omitted |
| Cursor | Read-only default `state.vscdb`, current WAL; Auto/API quotas and included-limit fallback | Composer headers with current editor-launch and freshness checks |
| Antigravity | Quota RPC from an already running IDE/CLI language server; otherwise derived local requests today | Recent transcript state; waits expire without live process evidence |
| Gemini | Gemini CLI recordings, OpenCode Google-provider message ledger and Hermes Gemini billing rows | Recent Gemini CLI recording writes, labelled as observed tool activity |
| OpenCode Go | Local SQLite/auth.json API key or OAuth; matching Go usage route | Not integrated; no hook/plugin installed |
| GitHub Copilot | `GH_TOKEN`/`GITHUB_TOKEN` or token in GitHub CLI `hosts.yml`; metered quota snapshots | Not integrated |
| Kimi Code | `KIMI_CODE_HOME` or `~/.kimi-code` credentials; weekly/rolling quotas | Live CLI process plus main-agent wire states, including approval waits |
| Grok | Trusted xAI-issued `~/.grok/auth.json` session; weekly billing quota | Not integrated |
| GLM | Matching Z.ai/BigModel Coding Plan keys from Claude Code, ZCode or OpenCode; owning console quota monitor | Not integrated |
| Ollama | Fixed `127.0.0.1:11434/api/ps`: loaded models, memory and context limits | No inferred activity or quota |
| LM Studio | Fixed `127.0.0.1:1234/api/v1/models`: loaded instances, model size and context limits | No inferred activity or quota |

Gemini reports derived **token counts**, not API-key quota percentages. Deduplicated Gemini CLI answer IDs, OpenCode cache/reasoning semantics and Hermes aggregate timestamps follow CodeNotch's parsers. Hermes sessions crossing a date boundary land in their last-seen bucket. Antigravity fallback reports derived **request counts** with quota unavailable. Runtime model listings are inventory, not inference activity or context consumption. Missing denominators leave the usage arc empty.

HeyMate-managed agent work keeps its separate chat link. External session rows are observational displays; they do not run agents, answer approvals or add chat backends. Busy/waiting/complete states only appear when local evidence supports them. No desktop app is called busy merely because it is running.

## Refresh, privacy and source reuse

Credentials are read locally, never logged, cached in usage preferences or sent to analytics. Requests refuse redirects and use fixed owning-provider endpoints. Only explicit Claude/custom-source Connect or Allow access can prompt for Keychain access; timers cannot. Borrowed tokens are never renewed or modified. Expired credentials renew in their owning tool. `gh auth token` is not spawned on a timer. Antigravity does not start a helper server or sign in to Google; its self-signed TLS exception is restricted to discovered loopback ports. No upstream phone server, updater, hooks or sign-in lifecycle is included.

Usage polls every two minutes; external activity scans every four seconds off the UI actor. Scans have file, byte, SQL and time limits; exceeding a limit rejects the entire reading rather than presenting a partial total. Disable removes usage cache/session state, cancels in-flight work, and rejects late results. Per-provider rate-limit backoff survives restarts. Transient failures keep the last reading visibly stale; authentication failures remove it. Cache contains quota/count values and timestamps, never session/project contents or runtime model names.

Actual motion geometry, spring vocabulary, ring layers, usage parsers and supported activity readers are vendored/adapted from [CodeNotch](https://github.com/vinzdg/codenotch), pinned to `6522e9f3ee0fe35d46e428b441e6e80b586eacbb`, under MIT. Full notice ships in `HeyMate/Codenotch-LICENSE.txt`; source map and changes live in `HeyMate/Codenotch/Codenotch-PROVENANCE.md`. This is a curated provider/read-only session integration, not full upstream provider/profile parity. Other providers can still use custom JSON sources.

## Custom sources

Settings → Notch → "Add your own source" connects any JSON usage endpoint: name, URL (HTTPS, or http on localhost), optional token and header name, a dot path to the percent (or used + limit paths), optional reset path (epoch seconds/ms or ISO date), and a logo. The token is stored in the Keychain (`HeyMate Notch Usage`), sent only to that URL, and deleted on Remove. Redirects are refused; a missing or non-numeric field reads as unavailable.

## File attachments

The notch does not accept file drops or store files for later sharing. Chat attachments remain part of the chat composer. The former shelf, bookmark storage, file-eating animation and AirDrop controls have been removed; old shelf bookmarks are no longer loaded. Original files are untouched.

Legacy micro-app preferences no longer start clipboard, camera, calendar or device monitors.
