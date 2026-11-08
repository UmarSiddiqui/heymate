# Phonon failure diagnosis and recovery (#90)

Issue #90 reports 87 generic service failures in 1.0.83 on an M5 Mac. The
report contains no HTTP status/body or server logs. Its exact historical
trigger cannot be established from that evidence.

The old generic message normally meant a non-200 speech response, not a
timeout. A malformed helper port shared the same message. Server stderr was
discarded, and a manifest marker let missing or corrupt cached blobs survive
restarts indefinitely.

The repair validates every cached blob's size and SHA-256 before starting a
server. Invalid stores are replaced from the verified bundled model. A damaged
bundle produces a reinstall message without deleting the existing store.
Replacement retains a backup until the new store is in place.

HTTP errors now include the status and one fixed category: model missing,
model invalid, voice invalid, input invalid, memory, runner, no audio, or unknown.
Helper/server stderr is drained into a bounded memory buffer and projected
into the same categories. Raw response bodies, paths, inputs and stderr are
never written to logs. An unknown error stays unknown rather than exposing
private text.

A server-side HTTP 5xx failure restarts the private helper/server and retries
once, only before delivering audio. HTTP 4xx and failures after audio has begun
are not retried. The production client retains its selected failure behavior;
this change does not enable a different voice or alter permissions.

## Executed checks (2026-11-08)

`python3 heymate/script/test_phonon_transport.py` compiles the production Swift
transport and exercises a disposable model store, HTTP server and helper. It
passes same-size blob corruption, missing blobs, damaged source preservation,
HTTP 400 classification/redaction, persistent 500 with bounded retry, 500 then
successful PCM, and a truncated stream without repeated audio.

`bash heymate/script/verify_voice_process.sh` passes persistent IPC, native trap
containment, fragmented replies, restart, timeout, cancellation and malformed
output. These fixtures do not establish the original reporter's exact trigger.
The updated transport still needs validation on that installation after release.

`PROBE_ROUNDS=5 bash heymate/script/verify_phonon.sh` also passed against the
canonical signed helper and real bundled Phonon: five replay segments, 40 calls
from overlapping callers across all ten voices, and 40 cancellation/recovery
cycles. These 85 real syntheses used a disposable model store and no GUI
install or preference changes.
