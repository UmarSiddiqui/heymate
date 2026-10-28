// Host adapter around the unchanged recovered H1 script runner. QuickJS gives
// the original AsyncFunction its own heap and globals, without Node or fetch.
import { readFileSync } from 'node:fs';
import { getQuickJS } from 'quickjs-emscripten';
import { validateToolArguments } from '@earendil-works/pi-ai';
import { gf } from './recovered-h1-script.mjs';

const original = readFileSync(new URL('./recovered-h1-script.mjs', import.meta.url), 'utf8')
  .replace('export { hf, uu, gf };', '');

export async function runRecoveredScript(code, { callTool, hasTool, onProgress = () => {}, signal, timeoutMs = 180000 } = {}) {
  signal?.throwIfAborted();
  if (typeof code !== 'string' || Buffer.byteLength(code) > 65536) throw new Error('Script exceeds 64 KiB.');
  const QuickJS = await getQuickJS();
  signal?.throwIfAborted();
  const runtime = QuickJS.newRuntime();
  runtime.setMemoryLimit(32 * 1024 * 1024);
  runtime.setMaxStackSize(512 * 1024);
  const deadline = Date.now() + Math.min(timeoutMs, 180000);
  runtime.setInterruptHandler(() => signal?.aborted || Date.now() >= deadline);
  const vm = runtime.newContext(), controller = new AbortController();
  const timers = new Map(), pending = new Set(), hostCalls = new Set();
  let alive = true, timerID = 0, stopped, fail;
  const stop = new Promise((_, reject) => { fail = reject; });
  const abort = () => { controller.abort(); fail(new Error(signal?.aborted ? 'Script cancelled.' : 'Script time limit reached.')); };
  const timeout = setTimeout(abort, Math.max(1, deadline - Date.now()));
  signal?.addEventListener('abort', abort, { once: true });
  const jobs = () => {
    if (!alive) return;
    const result = runtime.executePendingJobs();
    if (result.error) { const error = vm.dump(result.error); result.error.dispose(); fail(new Error(error?.message || 'Script interrupted.')); }
  };
  const install = (name, fn) => vm.newFunction(name, fn).consume(handle => vm.setProp(vm.global, name, handle));
  install('__has', name => hasTool(vm.getString(name)) ? vm.true : vm.false);
  install('__progress', text => { onProgress(vm.getString(text)); return vm.undefined; });
  install('__call', (name, args) => {
    const tool = vm.getString(name), parsed = JSON.parse(vm.getString(args));
    const deferred = vm.newPromise(); pending.add(deferred);
    const operation = Promise.resolve().then(() => {
      controller.signal.throwIfAborted();
      if (!hasTool(tool)) throw new Error('Tool unavailable.');
      return callTool(tool, parsed, controller.signal);
    }).then(result => {
      if (!alive) return;
      vm.newString(JSON.stringify(result)).consume(value => deferred.resolve(value));
    }, error => {
      if (!alive) return;
      vm.newError(String(error.message)).consume(value => deferred.reject(value));
    }).finally(() => {
      hostCalls.delete(operation);
      if (!alive) return;
      pending.delete(deferred); deferred.dispose(); jobs();
    });
    hostCalls.add(operation);
    return deferred.handle;
  });
  install('setInterval', (callback, delay) => {
    if (timers.size >= 8) return vm.throw(vm.newError('Too many script timers.'));
    const id = ++timerID, retained = callback.dup();
    const timer = setInterval(() => {
      if (!alive) return;
      const result = vm.callFunction(retained, vm.undefined);
      if (result.error) { result.error.dispose(); abort(); } else result.value.dispose();
      jobs();
    }, Math.max(10, vm.getNumber(delay)));
    timers.set(id, { timer, retained });
    return vm.newNumber(id);
  });
  install('clearInterval', id => {
    const timer = timers.get(vm.getNumber(id));
    if (timer) { clearInterval(timer.timer); timer.retained.dispose(); timers.delete(vm.getNumber(id)); }
    return vm.undefined;
  });
  let promise;
  try {
    const source = `${original}\nhf(${JSON.stringify(code)}, { callTool: async (name, args) => JSON.parse(await __call(name, JSON.stringify(args))), hasTool: __has, onProgress: __progress })`;
    promise = vm.unwrapResult(vm.evalCode(source));
    stopped = vm.resolvePromise(promise); jobs();
    const result = await Promise.race([stopped, stop]);
    const handle = vm.unwrapResult(result);
    try {
      const output = vm.dump(handle);
      if (pending.size) {
        output.ok = false;
        output.output += '\nError: Program ended before tool calls completed. Await every tool call.';
      }
      return output;
    } finally { handle.dispose(); }
  } finally {
    alive = false; controller.abort();
    let cleanupTimer;
    const settled = await Promise.race([
      Promise.allSettled([...hostCalls]).then(() => true),
      new Promise(resolve => { cleanupTimer = setTimeout(() => resolve(false), 1000); })
    ]);
    clearTimeout(cleanupTimer);
    clearTimeout(timeout); signal?.removeEventListener('abort', abort);
    for (const timer of timers.values()) { clearInterval(timer.timer); timer.retained.dispose(); }
    for (const deferred of pending) deferred.dispose();
    promise?.dispose();
    // resolvePromise owns guest callbacks until they settle. Interrupt cleanup
    // rejects the guest promise before freeing its context below.
    vm.dispose(); runtime.dispose();
    if (!settled) throw new Error('Script stopped waiting for a tool. Its outcome is unknown; verify before retrying.');
  }
}

export function scriptTool(tools, { emit = () => {}, telemetry = () => {} } = {}) {
  // No recursion, note updates or user-question tools. Their turn lifecycle
  // stays under the native host. Every exposed action uses its existing wrapper.
  const available = new Map(tools.filter(tool => !['exec', 'run_script', 'batch_read', 'ask_user'].includes(tool.name)
    && !tool.name.startsWith('note')).map(tool => [tool.name, tool]));
  const definition = gf([...available.values()].map(tool => ({ ...tool, parameters: tool.parameters })));
  return { name: definition.name, label: 'Run tool program', description: definition.description,
    parameters: definition.parameters, executionMode: 'sequential',
    async execute(id, { code }, signal) {
      let sequence = 0, writes = Promise.resolve();
      const result = await runRecoveredScript(code, {
        signal, hasTool: name => available.has(name), onProgress: text => emit('agent.progress', { text }),
        callTool: async (name, args, nestedSignal) => {
          const tool = available.get(name), callID = `${id}:${++sequence}`;
          args = validateToolArguments(tool, { type: 'toolCall', id: callID, name, arguments: args });
          const run = async () => {
            nestedSignal.throwIfAborted();
            const started = Date.now();
            try {
              const out = await tool.execute(callID, args, nestedSignal);
              telemetry({ type: 'tool_execution_end', toolCallId: callID, toolName: name, result: out, isError: !!out.isError, durationMs: Date.now() - started });
              return { text: (out.content ?? []).filter(part => part.type === 'text').map(part => part.text).join('\n'), ok: !out.isError };
            } catch (error) { telemetry({ type: 'tool_execution_end', toolCallId: callID, toolName: name, isError: true, durationMs: Date.now() - started }); throw error; }
          };
          telemetry({ type: 'tool_execution_start', toolCallId: callID, toolName: name });
          if (tool.executionMode !== 'sequential') return run();
          const next = writes.then(run, run); writes = next.catch(() => {}); return next;
        }
      });
      return { content: [{ type: 'text', text: result.output }], isError: !result.ok, details: { calls: result.calls, ms: result.ms } };
    } };
}
