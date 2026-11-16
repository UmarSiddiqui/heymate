// Long runs. A turn that reaches its step or time budget while the task is
// still in progress ends at a checkpoint instead of a wrapped-up partial
// answer; the app then starts a continuation turn on the same session. A
// stall, a cancel or a model error is never continued, and a turn whose client
// has no continuations left keeps the salvage answer it always had.

// Limit kinds pi-session reports. Only these two mean "out of budget, still working".
export const continuableLimits = Object.freeze(['steps', 'time']);

// Shown only if a checkpoint is ever delivered as a result (for example when
// the app restarts mid-chain), so it says plainly what state the task is in.
export const continuationText = 'This task reached a checkpoint while still in progress. Work already finished stayed done; ask me to continue it.';

/**
 * What to do after a turn ended.
 * @returns {'none'|'stop'|'continue'|'salvage'}
 *   none: no limit was hit; handle the answer normally.
 *   stop: the user cancelled; never continue or salvage.
 *   continue: end at a checkpoint so the client starts a continuation turn.
 *   salvage: answer from what was found (stall, error, or no continuations left).
 */
// modelError: the model call failed before the limit stopped it. The abort a limit
// causes can itself surface as an error stop, so the raw stop reason is not used.
export function continuationDecision({ limitKind = null, cancelled = false, modelError = false, allowContinuation = false } = {}) {
  if (cancelled) return 'stop';
  if (!limitKind) return 'none';
  if (!continuableLimits.includes(limitKind)) return 'salvage';
  if (modelError) return 'salvage';
  return allowContinuation === true ? 'continue' : 'salvage';
}
