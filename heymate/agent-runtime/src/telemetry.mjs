// Pi lifecycle adapter for the unchanged recovered H1 telemetry reducers/logger.
// Request bodies, response headers, tool arguments and result text never enter logs.
import { randomUUID } from 'node:crypto';
import { appendFileSync, chmodSync, mkdirSync, renameSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { addRoundEvent, newRoundStats, responseUsage, writeRoundEvent } from './recovered-h1-telemetry.mjs';

const MAX_LOG_BYTES = 1024 * 1024;
function privateAppend(file, value) {
  try {
    if (statSync(file).size >= MAX_LOG_BYTES) renameSync(file, `${file}.1`);
  } catch {}
  appendFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
}
function resultChars(result) {
  return (result?.content ?? []).reduce((n, part) => n + (part?.type === 'text' ? (part.text?.length ?? 0) : 0), 0);
}
const safeName = value => typeof value === 'string' && /^[a-zA-Z0-9_.:/-]{1,160}$/.test(value) ? value : 'unknown';

export function createTelemetry({ home, sessionID, model, provider, effort, now = Date.now, write } = {}) {
  const folder = home && path.join(home, 'logs');
  let diskReady = false;
  if (!write && folder) {
    try { mkdirSync(folder, { recursive: true, mode: 0o700 }); diskReady = true; } catch {}
  }
  let stats = newRoundStats(), request = null, calls = new Map();
  let compacting = false;
  function emit(event) {
    try {
      addRoundEvent(stats, event);
      const row = { session_id: sessionID, ...event };
      if (write) write(row);
      else if (diskReady) {
        privateAppend(path.join(folder, 'request-stats.jsonl'), row);
        // Preserve H1's original compact round/tool report as well as all timing marks.
        const rounds = path.join(folder, 'h1-rounds.jsonl');
        try { if (statSync(rounds).size >= MAX_LOG_BYTES) renameSync(rounds, `${rounds}.1`); } catch {}
        writeFileSync(rounds, '', { flag: 'a', mode: 0o600 });
        chmodSync(rounds, 0o600);
        writeRoundEvent({ state: folder, log() {} }, event);
      }
    } catch { /* Performance recording never changes the operation's outcome. */ }
  }
  function finishRequest(message, error) {
    if (!request) return;
    const usage = message?.usage;
    const normalized = usage ? responseUsage({ usage: {
      input_tokens: usage.input, input_tokens_details: { cached_tokens: usage.cacheRead },
      output_tokens: usage.output, output_tokens_details: { reasoning_tokens: usage.reasoning }
    } }) : null;
    if (normalized) {
      normalized.cache_write = usage.cacheWrite ?? 0;
      if (!Number.isFinite(usage.reasoning)) normalized.reasoning = null;
    }
    emit({ ...request, t_end: now(), usage: normalized,
      response_status: error ? 'failed' : message?.stopReason ?? 'unknown',
      function_calls: (message?.content ?? []).filter(part => part.type === 'toolCall').map(part => safeName(part.name)),
      // Error bodies can quote private prompts, tool results, URLs or credentials.
      error: error ? safeName(error) : null });
    request = null;
  }
  return {
    beforeRequest(payload) {
      if (request) finishRequest(null, 'superseded_request');
      let bytes = null;
      try { bytes = Buffer.byteLength(JSON.stringify(payload)); } catch {}
      request = { key: `model:${randomUUID()}`, kind: 'model_request', purpose: compacting ? 'compaction' : 'agent',
        model: safeName(model), provider: safeName(provider), effort: safeName(effort),
        t_send: now(), t_first_byte: null, t_first_reasoning: null, t_first_output: null,
        status: null, stream: true, request_bytes: bytes,
        timing_source: 'pi_provider_hooks', first_byte_observation: 'response_headers' };
    },
    afterResponse(status) {
      if (!request) return;
      request.t_first_byte ??= now();
      request.status = Number.isInteger(status) ? status : null;
    },
    onEvent(event) {
      if (event.type === 'agent_start') { stats = newRoundStats(); calls.clear(); compacting = false; }
      if (event.type === 'message_update' && request) {
        const type = event.assistantMessageEvent?.type;
        if (type === 'thinking_delta') request.t_first_reasoning ??= now();
        if (type === 'text_delta' || type === 'toolcall_delta') request.t_first_output ??= now();
      } else if (event.type === 'message_end' && event.message?.role === 'assistant') {
        finishRequest(event.message, ['error', 'aborted'].includes(event.message.stopReason) ? event.message.stopReason : null);
      } else if (event.type === 'tool_execution_start') {
        calls.set(event.toolCallId, { name: safeName(event.toolName), t: now() });
      } else if (event.type === 'tool_execution_end') {
        const call = calls.get(event.toolCallId);
        calls.delete(event.toolCallId);
        const early = event.result?.details?.early === true;
        const duration = early ? event.result.details.early_ms : event.durationMs;
        emit({ key: `tc:${safeName(event.toolCallId)}`, kind: 'tool_call', id: safeName(event.toolCallId),
          name: call?.name ?? safeName(event.toolName), server: 'heymate', t: early ? event.result.details.early_started : call?.t ?? null, t_end: now(),
          ok: !event.isError, error: event.isError ? 'tool_failed' : null,
          ...(early ? { early: true } : {}),
          result_chars: resultChars(event.result),
          ...(Number.isFinite(duration) && duration >= 0 ? { exec_ms: duration } : {}) });
      } else if (event.type === 'compaction_start' || event.type === 'auto_compaction_start') {
        compacting = true; emit({ key: `compact:${randomUUID()}`, kind: 'compaction', t: now() });
      } else if (event.type === 'compaction_end' || event.type === 'auto_compaction_end') compacting = false;
      else if (event.type === 'agent_end') {
        if (request) finishRequest(null, 'interrupted_request');
        for (const [id, call] of calls) emit({ key: `tc:${safeName(id)}`, kind: 'tool_call', id: safeName(id),
          name: call.name, server: 'heymate', t: call.t, t_end: now(), ok: false, error: 'interrupted', result_chars: 0 });
        calls.clear();
      }
    },
    snapshot() { return { ...stats }; }
  };
}
