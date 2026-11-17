import test from 'node:test';
import assert from 'node:assert/strict';
import { continuationDecision } from '../src/continuation.mjs';

test('only an out-of-budget turn with continuations left continues', () => {
  const base = { limitKind: 'steps', cancelled: false, modelError: false, allowContinuation: true };
  assert.equal(continuationDecision(base), 'continue');
  assert.equal(continuationDecision({ ...base, limitKind: 'time' }), 'continue');
  assert.equal(continuationDecision({ ...base, limitKind: 'stall' }), 'salvage');
  assert.equal(continuationDecision({ ...base, cancelled: true }), 'stop');
  assert.equal(continuationDecision({ ...base, limitKind: 'stall', cancelled: true }), 'stop');
  assert.equal(continuationDecision({ ...base, modelError: true }), 'salvage');
  assert.equal(continuationDecision({ ...base, allowContinuation: false }), 'salvage');
  assert.equal(continuationDecision({ ...base, allowContinuation: 'yes' }), 'salvage');
  assert.equal(continuationDecision({ ...base, limitKind: null }), 'none');
  assert.equal(continuationDecision(), 'none');
});
