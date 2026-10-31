// Durable tool and model result journal.
import { mkdirSync, openSync, readFileSync, writeSync, fsyncSync, ftruncateSync, closeSync, constants } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { validID } from './store.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const redact = value => String(value ?? '').replace(/(sk-|xox[a-z]-|ghp_|Bearer\s+)[A-Za-z0-9._-]{8,}/gi, '$1[redacted]');

class PrivateJournalDisk {
  constructor(folder) {
    this.folder = folder;
    this.tails = new Map();
    mkdirSync(folder, { recursive: true, mode: 0o700 });
  }
  file(name) {
    if (!['steps.jsonl', 'started.jsonl'].includes(name)) throw new Error('Invalid journal file.');
    return path.join(this.folder, name);
  }
  readLines(name) {
    let source;
    const file = this.file(name);
    let fd;
    try {
      fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
      source = readFileSync(fd, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    } finally { if (fd !== undefined) closeSync(fd); }
    // A process can die during its final append. Only that unterminated tail is
    // discarded; corrupt complete records must never permit silent action replay.
    const lines = source.split('\n');
    if (lines.at(-1) !== '') {
      lines.pop();
      this.tails.set(name, Buffer.byteLength(source.slice(0, source.lastIndexOf('\n') + 1)));
    } else this.tails.delete(name);
    return lines.filter(Boolean).map(line => {
      const value = JSON.parse(line);
      if (!value || typeof value.key !== 'string') throw new Error('Invalid journal record.');
      if (name === 'steps.jsonl' && (('value' in value) === ('error' in value))) throw new Error('Invalid completed journal record.');
      return value;
    });
  }
  append(name, value) {
    const sanitized = typeof value.error === 'string' ? { ...value, error: redact(value.error) } : value;
    const data = Buffer.from(`${JSON.stringify(sanitized)}\n`);
    const fd = openSync(this.file(name), constants.O_WRONLY | constants.O_CREAT | constants.O_APPEND | constants.O_NOFOLLOW, 0o600);
    try {
      if (this.tails.has(name)) {
        ftruncateSync(fd, this.tails.get(name));
        this.tails.delete(name);
      }
      let written = 0;
      while (written < data.length) written += writeSync(fd, data, written, data.length - written);
      fsyncSync(fd);
    } finally { closeSync(fd); }
    const directory = openSync(this.folder, constants.O_RDONLY);
    try { fsyncSync(directory); } finally { closeSync(directory); }
  }
}

export class StepJournal {
  constructor({ home, sessionID }) {
    if (!path.isAbsolute(home) || !validID(sessionID)) throw new Error('Invalid journal identity.');
    this.disk = new PrivateJournalDisk(path.join(home, 'desktop', 'journal', sessionID));
    this.active = new Map();
    this.started = new Map(this.disk.readLines('started.jsonl').map(row => [row.key, row]));
    // Validate completed records before a new operation can reach its callback.
    this.done = new Map(this.disk.readLines('steps.jsonl').map(row => [row.key, row]));
  }

  // Pi owns model execution and its transcript. This stores the complete model
  // outcome in the step journal before native UI completion,
  // closing the crash window between those two persistence paths.
  checkpointModel({ id, turnID, message }) {
    if (typeof turnID !== 'string' || !turnID || message?.role !== 'assistant') throw new Error('Invalid model checkpoint.');
    const snapshot = structuredClone(message);
    return this.run({ name: 'model-result', id, args: { turnID, message: snapshot }, kind: 'model' }, async () => ({ turnID, message: snapshot }));
  }

  modelResults(turnID) {
    return [...this.done.values()].filter(row => row.value?.turnID === turnID && row.value?.message?.role === 'assistant')
      .map(row => structuredClone(row.value.message));
  }

  // Only the host calls this, after checking the final answer and completing
  // its bounded note-finishing pass. A model stop message alone is not proof
  // that native completion was ready to publish.
  checkpointAnswer({ turnID, answer }) {
    if (typeof turnID !== 'string' || !turnID || typeof answer !== 'string' || !answer.trim()) throw new Error('Invalid final-answer checkpoint.');
    return this.run({ name: 'native-final-answer', id: turnID, args: { turnID, answer }, kind: 'model' }, async () => ({
      type: 'native-final-answer', turnID, answer
    }));
  }

  completedAnswer(turnID) {
    const record = [...this.done.values()].find(row => row.value?.type === 'native-final-answer' && row.value.turnID === turnID);
    return typeof record?.value?.answer === 'string' && record.value.answer.trim() ? record.value.answer : null;
  }

  run({ name, id, args = {}, kind = 'read', signal, policy = { retries: { limit: 0 } } }, operation) {
    if (typeof name !== 'string' || !name || typeof id !== 'string' || !id || !['read', 'write', 'model'].includes(kind)) {
      throw new Error('A stable tool/model call identity and journal kind are required.');
    }
    signal?.throwIfAborted();
    const step = `${kind === 'write' ? 'write' : kind === 'model' ? 'model' : 'tools'} ${hash(JSON.stringify([name, id]))}`;
    const key = `do:${step}`;
    const fingerprint = hash(JSON.stringify([name, id, kind, args]));
    const prior = this.started.get(key);
    if (prior && prior.fingerprint !== fingerprint) throw new Error('Journal call identity reused with different arguments.');
    const active = this.active.get(key);
    if (active) return active;
    // Before-start markers preserve uncertain writes across a crash.
    if (kind === 'write' && prior && !this.done.has(key)) {
      throw new Error('This action may already have run; its outcome is unknown. Check before trying again.');
    }
    if (!prior) {
      const marker = { key, fingerprint, kind };
      this.disk.append('started.jsonl', marker);
      this.started.set(key, marker);
    }
    const run = (async () => {
      const previous = this.done.get(key);
      if (previous) {
        if ('error' in previous) throw new Error(previous.error);
        return previous.value;
      }
      const limit = kind === 'write' ? 0 : Math.max(0, Math.min(10, Number(policy?.retries?.limit) || 0));
      for (let attempt = 0; ; attempt++) {
        signal?.throwIfAborted();
        let value;
        try { value = await operation(); }
        catch (error) {
          const message = redact(error?.message ?? error);
          if (!signal?.aborted && error?.name !== 'NonRetryableError' && attempt < limit) {
            const delay = policy?.retries?.delay;
            const match = typeof delay === 'string' && delay.match(/^(\d+(?:\.\d+)?)\s*(milliseconds?|seconds?|minutes?)$/i);
            const ms = match ? Number(match[1]) * (/^minutes?/i.test(match[2]) ? 60000 : /^seconds?/i.test(match[2]) ? 1000 : 1) : 0;
            if (ms) await new Promise((resolve, reject) => {
              const abort = () => { clearTimeout(timer); reject(signal.reason ?? new Error('Aborted')); };
              const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, Math.min(ms, 60000));
              signal?.addEventListener('abort', abort, { once: true });
              if (signal?.aborted) abort();
            });
            continue;
          }
          // An interrupted call without a durable result must not become a
          // completed failure: writes remain uncertain and reads can retry.
          if (signal?.aborted) throw error;
          this.disk.append('steps.jsonl', { key, error: message });
          throw new Error(message);
        }
        if (value === undefined) throw new Error('Journal operation returned no serializable result.');
        this.disk.append('steps.jsonl', { key, value });
        return value;
      }
    })();
    const result = run.finally(() => {
      this.active.delete(key);
      // Only publish journal records actually written successfully.
      this.done = new Map(this.disk.readLines('steps.jsonl').map(row => [row.key, row]));
    });
    this.active.set(key, result);
    return result;
  }
}
