// A mate's heartbeat: one short, read-only turn in which the mate looks at its own
// context and proposes work (the app parses the proposals). The tool boundary is
// enforced here, not in the prompt: no write, edit, bash, browser actions, questions,
// note edits, programs or messages to other mates ever reach a heartbeat session.
import path from 'node:path';
import { realpath } from 'node:fs/promises';
import { clampThinkingLevel } from '@earendil-works/pi-ai';

// Well under a normal turn (pi-session turnLimits: 60 steps, 280 s).
export const heartbeatLimits = { steps: 8, ms: 75000, nudgeAt: 0.6, stallMs: 30000, toolStallMs: 45000 };

const builtinReads = new Set(['read']);
const namedReads = new Set(['note_read', 'web_search', 'web_fetch']);
// Never allowed, whatever a connector claims about itself.
const denied = /(^|_)(send_to_mate|answer_request|create_mate|ask_person|ask_user|use_browser|use_chrome|browser)$/i;

export const heartbeatGuide = 'HEARTBEAT: this is a private, read-only check-in, not a chat. Nobody is watching it live. '
  + 'You can only read: your own folder with read, the web with web_search and web_fetch, and read-only app tools. '
  + 'Nothing you do here may change anything. Answer only in the requested format.';

/** Validated heartbeat options from prompt.submit, or null for a normal turn. Throws on a malformed value. */
export function heartbeatOptions(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid heartbeat.');
  const root = value.read_root;
  if (root !== undefined && root !== null && (typeof root !== 'string' || !path.isAbsolute(root) || root.length > 4096)) {
    throw new Error('Invalid heartbeat.');
  }
  return { readRoot: typeof root === 'string' ? root : null };
}

/** Builtin coding tools a heartbeat keeps: read only. */
export const heartbeatKeepsBuiltin = name => builtinReads.has(name);

/** The harness's custom tools narrowed to unconditional reads. Keeps the batchReads marker. */
export function heartbeatTools(tools) {
  const reads = new Map((tools.batchReads ?? []).map(entry => [entry.tool.name, entry]));
  const allowed = tools.filter(tool => {
    if (denied.test(tool.name)) return false;
    if (namedReads.has(tool.name)) return true;
    // Read-only connector tools are batch reads without a per-call condition.
    const entry = reads.get(tool.name);
    return !!entry && entry.allows === undefined;
  });
  const names = new Set(allowed.map(tool => tool.name));
  Object.defineProperty(allowed, 'batchReads', { value: (tools.batchReads ?? []).filter(entry => names.has(entry.tool.name)) });
  return allowed;
}

const inside = (root, target) => target === root || target.startsWith(root.endsWith(path.sep) ? root : root + path.sep);

/** Wraps Pi's read tool so it reads only inside `root` (relative paths start there); without a root it reads nothing. */
export function confineRead(tool, root) {
  return { ...tool, execute: async (id, params, signal, onUpdate) => {
    if (!root) throw new Error('This heartbeat has no folder to read.');
    const requested = typeof params?.path === 'string' ? params.path : '';
    let target, base;
    try {
      base = await realpath(root);
      target = await realpath(path.resolve(base, requested));
    } catch { throw new Error('That file is not in this mate’s folder.'); }
    if (!inside(base, target)) throw new Error('That file is not in this mate’s folder.');
    return tool.execute(id, { ...params, path: target }, signal, onUpdate);
  } };
}

/** The lowest reasoning effort this model supports. */
export const heartbeatEffort = model => clampThinkingLevel(model, 'minimal');
