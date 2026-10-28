// HeyMate's bounded equivalent of H1 read batching. No model-written JS is
// evaluated: each call still crosses its original scoped tool boundary.
export function batchReadTool(entries) {
  const allowed = new Map(entries.map(({ tool, allows = () => true }) => [tool.name, { tool, allows }]));
  return { name: 'batch_read', label: 'Read several sources',
    description: 'Run 1–8 independent read-only calls in one model round. Available tools: ' + [...allowed.keys()].join(', ') + '. Writes, questions, shell commands and nested batches are refused. Results retain input order and per-call errors.',
    parameters: { type: 'object', properties: { calls: { type: 'array', minItems: 1, maxItems: 8,
      items: { type: 'object', properties: { tool: { type: 'string', enum: [...allowed.keys()] }, arguments: { type: 'object' } }, required: ['tool', 'arguments'], additionalProperties: false } } }, required: ['calls'], additionalProperties: false },
    execute: async (id, { calls }, signal) => {
      signal?.throwIfAborted();
      if (!Array.isArray(calls) || calls.length < 1 || calls.length > 8) throw new Error('batch_read requires 1–8 calls.');
      // Validate the entire batch before executing even one call.
      for (const call of calls) if (!allowed.has(call?.tool) || !call.arguments || Array.isArray(call.arguments)
        || typeof call.arguments !== 'object' || !allowed.get(call.tool).allows(call.arguments)) throw new Error('Batch contains a non-read or unavailable tool. Nothing ran.');
      const results = await Promise.all(calls.map(async (call, index) => {
        try {
          signal?.throwIfAborted();
          const result = await allowed.get(call.tool).tool.execute(`${id}:${index}`, call.arguments, signal);
          const text = (result.content ?? []).filter(p => p.type === 'text').map(p => p.text).join('\n');
          return { tool: call.tool, ok: !result.isError, text: text.slice(0, Math.floor(24000 / calls.length)), truncated: text.length > Math.floor(24000 / calls.length) };
        } catch (error) { return { tool: call.tool, ok: false, error: String(error.message).slice(0, 500) }; }
      }));
      signal?.throwIfAborted();
      return { content: [{ type: 'text', text: JSON.stringify(results) }], details: { count: calls.length } };
    } };
}
