// Pi adapter for H1's unchanged early-read closure. Only explicitly read-only
// tools may start before model streaming ends. Browser calls stay ordered.
import { validateToolArguments } from '@earendil-works/pi-ai';
import { recoveredEarlyReads } from './recovered-h1-early-reads.mjs';

export function earlyReads(entries, { signal = () => undefined, isActive = () => true } = {}) {
  const allowed = new Map(entries.filter(entry => entry.speculative !== false)
    .map(entry => [entry.tool.name, entry]));
  let early, argumentsByID = new Map(), completedAt = new Map();
  const execute = async call => {
    const entry = allowed.get(call.name);
    const result = await entry.tool.execute(call.callId, call.args, signal());
    return { content: result.content ?? [], isError: !!result.isError };
  };
  const reset = () => {
    early = recoveredEarlyReads({ cn: async () => null,
      cu: async () => { throw new Error('Web speculation unavailable.'); },
      tt: async (_host, prepared) => {
        const result = await execute({ name: prepared.c.name, callId: prepared.c.call_id, args: prepared.args });
        return { content: result.content, ok: !result.isError };
      }, wt: error => String(error?.message ?? error).slice(0, 600) });
    argumentsByID = new Map();
    completedAt = new Map();
  };
  reset();
  return {
    reset,
    onEvent(event) {
      const update = event.assistantMessageEvent;
      if (event.type !== 'message_update' || update?.type !== 'toolcall_end') return;
      const call = update.toolCall, entry = allowed.get(call?.name);
      if (!entry || !isActive(call.name) || signal()?.aborted || early.results.has(call.id)) return;
      let args;
      try {
        args = validateToolArguments(entry.tool, call);
        if (entry.allows && !entry.allows(args)) return;
        args = JSON.parse(JSON.stringify(args));
      } catch { return; }
      argumentsByID.set(call.id, JSON.stringify([call.name, args]));
      early.start({ boxTool: execute }, { c: { call_id: call.id, name: call.name }, args,
        cls: call.name === 'read' ? 'box' : 'mcpRead' });
      const completion = completedAt;
      early.results.get(call.id).then(() => completion.set(call.id, Date.now()));
    },
    async take(id, name, args) {
      const promise = early.results.get(id);
      if (!promise) return null;
      if (argumentsByID.get(id) !== JSON.stringify([name, args])) throw new Error('Early read identity changed.');
      const result = await promise;
      return { content: result.content, isError: !result.ok,
        details: { early: true, early_started: result.t, early_ms: (completedAt.get(id) ?? Date.now()) - result.t } };
    }
  };
}
