// HeyMate's tool-program runner. QuickJS evaluates this file (script-tools.mjs strips the
// export line) so the program runs in that heap, not in Node. The names hf, uu and gf are the
// entry points that host still calls.
const TRANSCRIPT_LIMIT = 20000;
const DEADLINE_MS = 180000;
const TICK_MS = 1000;
const PROGRESS_LIMIT = 20;
const PROGRESS_CHARS = 160;
const timedTools = new Set(['mac_step']);

const uu = {
  type: 'function',
  name: 'run_script',
  strict: false,
  description:
    'Write a small JavaScript program that calls your tools for you. Reach for it when the same call repeats across many items (16 emails to open, 10 pages to read, a row to fill for each person) or when a result is large and you need only a few facts from it; for one or two calls, call the tools yourself. `code` is the body of an async function. Each app and browser tool is `await tools.NAME(args)`, taking the same arguments as when you call it directly (e.g. `await tools.COMPOSIO_MULTI_EXECUTE_TOOL({tools: [...]})`, `await tools.browser({operation: "extract", tabId})`); it returns the result, parsed when it is JSON and as text otherwise, and throws when the call fails. Start independent calls together with Promise.all. You see only what the program prints with text(...) or returns, up to 20,000 characters, so print what you need and no more. progress("Read 12 of 30") puts a short status line in front of the user while it runs. A program may run for 3 minutes. It cannot touch files or the network itself: bash handles files and fetch_url fetches pages.',
  parameters: {
    type: 'object',
    required: ['code'],
    properties: {
      code: {
        type: 'string',
        description: 'The body of an async function, using tools.NAME(args) and text(...).',
      },
    },
  },
};

function formatValue(value) {
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value, null, 1);
  } catch {
    return String(value);
  }
}

async function hf(code, { callTool, hasTool, onProgress = () => {} }) {
  const lines = [];
  let counted = 0;
  const print = (...args) => {
    const line = args.map(formatValue).join(' ');
    // Keep only what the cut can still return. The counted length still includes the
    // whole print, so the cut notice appears in the same place as before.
    if (counted < TRANSCRIPT_LIMIT) {
      const room = TRANSCRIPT_LIMIT - counted;
      lines.push(line.length > room ? line.slice(0, room) : line);
    }
    counted += line.length + 1;
  };

  let calls = 0;
  let inTimed = 0;
  let timedMs = 0;
  let timedStart = 0;
  const tools = new Proxy({}, {
    get(_target, name) {
      if (typeof name !== 'string' || name === 'then') return undefined;
      if (name === 'toString' || name === 'valueOf' || name === 'toLocaleString') {
        return () => '[tools: call await tools.NAME(args)]';
      }
      if (name in Object.prototype || name === 'toJSON' || name === 'inspect' || name === 'constructor') {
        return undefined;
      }
      return (args = {}) => {
        const pending = (async () => {
          if (!hasTool(name)) throw new Error(`There is no tool named ${name}.`);
          calls += 1;
          const timed = timedTools.has(name);
          if (timed && inTimed++ === 0) timedStart = Date.now();
          let result;
          try {
            result = await callTool(name, args);
          } finally {
            if (timed && --inTimed === 0) timedMs += Date.now() - timedStart;
          }
          if (!result.ok) throw new Error(`${name} failed: ${String(result.text).slice(0, 2000)}`);
          try {
            return JSON.parse(result.text);
          } catch {
            return result.text;
          }
        })();
        // A program that forgets to await still owns the promise. This handler only
        // stops an ignored failure from aborting the guest; awaiting still throws.
        pending.catch(() => {});
        return pending;
      };
    },
  });

  let progressCount = 0;
  const reportProgress = (message) => {
    const line = String(message ?? '').replace(/\s+/g, ' ').trim().slice(0, PROGRESS_CHARS);
    if (!line || progressCount++ >= PROGRESS_LIMIT) return;
    try {
      onProgress(line);
    } catch {
      // A progress listener must not stop the program.
    }
  };

  const started = Date.now();
  let returned;
  let failure = null;
  let timer;
  try {
    const AsyncFunction = (async () => {}).constructor;
    const programFn = new AsyncFunction(
      'tools', 'text', 'progress', 'console', 'process', 'require', 'Bun', 'globalThis',
      `'use strict';\n${code}`,
    );
    const consoleBridge = { log: print, info: print, warn: print, error: print };
    const program = programFn(tools, print, reportProgress, consoleBridge, undefined, undefined, undefined, undefined);
    program.catch(() => {});
    const deadline = new Promise((_resolve, reject) => {
      let elapsed = 0;
      timer = setInterval(() => {
        if (inTimed > 0) return;
        elapsed += TICK_MS;
        if (elapsed >= DEADLINE_MS) reject(new Error('The program ran past 180 s and was stopped.'));
      }, TICK_MS);
    });
    returned = await Promise.race([program, deadline]);
  } catch (error) {
    failure = error?.message || String(error);
  } finally {
    if (timer !== undefined) clearInterval(timer);
  }

  let output = lines.join('\n');
  if (returned !== undefined && !failure) {
    output += `${output ? '\n' : ''}${formatValue(returned)}`;
  }
  if (counted > TRANSCRIPT_LIMIT || output.length > TRANSCRIPT_LIMIT) {
    output = `${output.slice(0, TRANSCRIPT_LIMIT)}\n… (cut at ${TRANSCRIPT_LIMIT} characters: print less)`;
  }
  if (failure) output = `${output ? `${output}\n` : ''}Error: ${failure}`;
  if (inTimed > 0) timedMs += Date.now() - timedStart;
  return {
    output: output || '(the program printed nothing)',
    ok: !failure,
    calls,
    ms: Date.now() - started,
    userWaitMs: timedMs,
  };
}

function gf(tools) {
  const catalogue = tools.map((tool) => {
    const required = tool.parameters?.required || [];
    const fields = Object.entries(tool.parameters?.properties || {}).map(([name, schema]) => {
      const optional = required.includes(name) ? '' : '?';
      return `${name}${optional}: ${schema.type || 'any'}`;
    }).join(', ');
    return `- tools.${tool.name}({${fields}}): ${tool.description || ''}`;
  }).join('\n');
  return {
    ...uu,
    name: 'exec',
    description: `JavaScript run as the body of an async function, and the only way to call your app and browser tools: \`await tools.NAME(args)\` gives the tool's result (parsed when it is JSON, otherwise text) and throws when the call fails. Start calls that do not depend on each other together in one exec (Promise.all or Promise.allSettled); keep actions whose order matters one after another. You see only what you print with text(...) or return, up to 20,000 characters, so print what the next decision needs. progress("Read 12 of 30") shows the user a short status line meanwhile. When you have to see results before choosing what to do, finish this exec and start another. Each call may take 3 minutes and has no files or network of its own (bash and fetch_url do those).
The tools:
${catalogue}`,
  };
}

export { hf, uu, gf };
