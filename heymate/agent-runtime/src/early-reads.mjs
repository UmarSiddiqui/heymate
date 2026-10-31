// Start eligible read-only tools as soon as their complete arguments arrive.
// The ordinary tool path reuses the result only when its identity still matches.
import { validateToolArguments } from '@earendil-works/pi-ai';

export function earlyReads(entries, { signal = () => undefined, isActive = () => true } = {}) {
  const allowed = new Map(entries.filter(entry => entry.speculative !== false)
    .map(entry => [entry.tool.name, entry]));
  let pending = new Map();
  return {
    reset() { pending = new Map(); },
    onEvent(event) {
      const update = event.assistantMessageEvent;
      if (event.type !== 'message_update' || update?.type !== 'toolcall_end') return;
      const call = update.toolCall, entry = allowed.get(call?.name);
      if (!entry || !isActive(call.name) || signal()?.aborted || pending.has(call.id)) return;
      let args, identity;
      try {
        args = validateToolArguments(entry.tool, call);
        if (entry.allows && !entry.allows(args)) return;
        args = JSON.parse(JSON.stringify(args));
        identity = JSON.stringify([call.name, args]);
      } catch { return; }
      const started = Date.now();
      const record = { identity, started, finished: null, promise: null };
      pending.set(call.id, record);
      try {
        record.promise = Promise.resolve(entry.tool.execute(call.id, args, signal()));
      } catch (error) { record.promise = Promise.reject(error); }
      record.promise = record.promise.then(
        result => ({ content: result?.content ?? [], isError: !!result?.isError }),
        error => ({ content: [{ type: 'text', text: String(error?.message ?? error).slice(0, 600) }], isError: true })
      ).then(result => { record.finished = Date.now(); return result; });
    },
    async take(id, name, args) {
      const record = pending.get(id);
      if (!record) return null;
      if (record.identity !== JSON.stringify([name, args])) throw new Error('Early read identity changed.');
      const result = await record.promise;
      return { ...result, details: { early: true, early_started: record.started,
        early_ms: (record.finished ?? Date.now()) - record.started } };
    }
  };
}
