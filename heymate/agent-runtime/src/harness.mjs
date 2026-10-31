import { fetchModelSpeeds, speedAccount } from './model-speeds.mjs';
import { brainProviders, hasBrainCredential, configureBrain, modelEfforts } from './brain.mjs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { appendFile, mkdir, readFile, readdir, realpath, rename, rm, stat, writeFile } from 'node:fs/promises';
import { noteHash, noteClosingIssues } from './note-workflow.mjs';
import { noteEdits, noteToolDefinitions } from './notes.mjs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { SessionStore, validID, readJSON, saveJSON } from './store.mjs';
import { StepJournal } from './step-journal.mjs';

const boundedText = (value, max) => typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= max;
const errorText = 'HeyMate could not finish this operation. Check model access or retry after reviewing progress.';
// Provider errors can echo request fragments; never surface or log token-shaped text.
const redact = value => String(value ?? '').replace(/(sk-|xox[a-z]-|ghp_|Bearer\s+)[A-Za-z0-9._-]{8,}/gi, '$1[redacted]');
const validSeed = seed => Array.isArray(seed) && seed.length <= 200
  && seed.every(row => (row?.role === 'user' || row?.role === 'assistant') && boundedText(row.content, 65536))
  && Buffer.byteLength(JSON.stringify(seed)) <= 262144;

export class HeyMateHarness {
  constructor({ home, access, createSession }) {
    this.home = home; this.access = access; this.createSession = createSession;
    this.store = new SessionStore(home); this.epoch = randomUUID();
    this.sessions = new Map(); this.bridges = new Map(); this.logins = new Map();
  }
  async get(id) {
    if (!validID(id)) throw new Error('Invalid session identity.');
    if (!this.sessions.has(id)) {
      const record = await this.store.load(id);
      if (!record) throw new Error('Session not found.');
      if (record.pending && record.activeTurnID) {
        const journal = new StepJournal({ home: this.home, sessionID: record.id });
        const answer = journal.completedAnswer(record.activeTurnID);
        if (answer) {
          record.rows.push({ id: record.rows.length + 1, role: 'assistant', content: answer, finish_reason: 'stop' });
          record.pending = false;
          await this.store.save(record);
        }
      }
      this.sessions.set(id, { record, events: [], sequence: 0, peers: new Set(), images: [],
        requests: new Map(), session: null, running: false, run: null, cancelled: false, bridgeNames: new Set() });
    }
    return this.sessions.get(id);
  }
  emit(state, type, payload) {
    const event = { session_id: state.record.id, seq: ++state.sequence, type, payload };
    state.events.push(event);
    while (state.events.length > 512 || Buffer.byteLength(JSON.stringify(state.events)) > 3 * 1024 * 1024) state.events.shift();
    for (const peer of state.peers) peer.send({ jsonrpc: '2.0', method: 'event', params: event });
  }
  snapshot(state) {
    return { session_id: state.record.id, stored_session_id: state.record.id, session_key: state.record.id,
      running: state.running, info: { cwd: state.record.cwd, desktop_contract: 8 }, open_requests: [...state.requests.values()].map(r => r.message) };
  }
  async ask(state, method, params, signal) {
    signal?.throwIfAborted();
    const peer = [...state.peers].reverse().find(p => p.serverRequests && p.open());
    if (!peer) throw new Error('No native approval window is connected.');
    const id = randomUUID();
    const message = { jsonrpc: '2.0', id, method, params: { ...params, session_id: state.record.id } };
    state.session?.holdBudget?.(true);
    return new Promise((resolve, reject) => {
      const finish = (error, value) => {
        if (!state.requests.delete(id)) return;
        state.session?.holdBudget?.(false);
        clearTimeout(timer); signal?.removeEventListener('abort', abort);
        this.emit(state, 'request.cancel', { id });
        error ? reject(error) : resolve(value);
      };
      const abort = () => finish(new Error('Request cancelled.'));
      const timer = setTimeout(() => finish(new Error('Approval expired.')), 120000);
      state.requests.set(id, { message, finish });
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) abort(); else peer.send(message);
    });
  }
  async approve(state, name, args, signal) {
    const response = await this.ask(state, 'approval', { choices: ['once', 'deny'],
      title: `Allow ${name}?`, description: JSON.stringify(args).slice(0, 3500) }, signal);
    if (response?.choice !== 'once') throw new Error('User did not approve this operation.');
  }
  answer(peer, message) {
    for (const state of this.sessions.values()) {
      const request = state.requests.get(message.id);
      if (request && state.peers.has(peer)) request.finish(message.error ? new Error('Request denied.') : null, message.result);
    }
  }
  disconnect(peer) {
    for (const state of this.sessions.values()) {
      state.peers.delete(peer);
      // A lost UI connection cannot grant permissions. Work may reconnect through replay.
      if (!state.peers.size) for (const request of [...state.requests.values()]) request.finish(new Error('Approval window disconnected.'));
    }
  }
  async tools(state) {
    const tools = [];
    const batchReads = [];
    for (const name of state.bridgeNames) {
      const bridge = this.bridges.get(name);
      if (!bridge || bridge.sessionID !== state.record.id) continue;
      for (const tool of bridge.tools) {
        const readOnly = tool.annotations?.readOnlyHint === true;
        const call = async (id, args, signal) => {
          signal?.throwIfAborted();
          const current = this.bridges.get(name);
          if (!current || current.sessionID !== state.record.id || !state.running) throw new Error('Connector scope expired.');
          // The native scoped bridge enforces current-turn action approvals too.
          const result = await current.client.callTool({ name: tool.name, arguments: args,
            ...(id ? { _meta: { 'heymate/idempotency_key': id } } : {}) }, undefined, { signal });
          if (result.isError) {
            // Keep the tool's own reason: without it the model can only say "it failed".
            const reason = (result.content ?? []).filter(part => part.type === 'text').map(part => part.text).join('\n').trim().slice(0, 500);
            throw new Error(`Connector action failed${reason ? `: ${reason}` : ''}. Inspect returned tool evidence before reporting success.`);
          }
          return { content: result.content ?? [], details: {} };
        };
        const adapted = { name: `${name}_${tool.name}`, label: tool.name, description: tool.description || tool.name,
          parameters: tool.inputSchema,
          // Reads may run beside each other; writes run one at a time, keyed and ledgered.
          ...(readOnly ? {} : { executionMode: 'sequential' }),
          execute: (id, args, signal) => readOnly ? call(null, args, signal)
            : this.sideEffect(state, `${name}_${tool.name}`, args, id, key => call(key, args, signal))
        };
        tools.push(adapted);
        if (readOnly) batchReads.push({ tool: adapted });
        else if (tool.name === 'use_chrome') batchReads.push({ tool: adapted, allows: args => ['tabs', 'snapshot', 'read', 'extract'].includes(args.op) });
      }
    }
    // ReferenceRenderer's note tools (notes.mjs): one note per chat, kept as markdown in HeyMate's Notes folder, which the
    // app watches, so the user sees the page change as each edit lands.
    for (const definition of noteToolDefinitions) {
      tools.push({ name: definition.name, label: definition.name, description: definition.description,
        parameters: definition.parameters, executionMode: 'sequential',
        execute: async (id, args, signal) => {
          signal?.throwIfAborted();
          (state.closedNotePreviews ??= new Set()).add(id);
          await state.notePreviewWrite;
          await this.clearNotePreview(state);
          const saved = await this.editNote(state, definition.name, args ?? {}, id);
          return { content: [{ type: 'text', text: saved }], details: {} };
        } });
    }
    tools.push({ name: 'note_read', label: 'Read this chat’s note',
      description: 'Read the saved note for this chat before continuing earlier work or after compaction. Returns the current markdown without changing it.',
      parameters: { type: 'object', properties: {}, additionalProperties: false },
      execute: async (_id, _args, signal) => {
        signal?.throwIfAborted();
        await state.noteWrite;
        const markdown = await this.readNote(state);
        return { content: [{ type: 'text', text: markdown || 'This chat has no saved note.' }], details: {} };
      } });
    tools.push({ name: 'ask_user', label: 'Ask a question',
      description: 'Ask the user one short question when a required fact or decision is missing. Offer up to 6 likely answers as choices; the user may still type their own. The turn pauses until they answer.',
      parameters: { type: 'object', properties: { question: { type: 'string' },
        choices: { type: 'array', items: { type: 'string' }, maxItems: 6 } }, required: ['question'], additionalProperties: false },
      execute: async (_id, args, signal) => {
        const question = String(args.question ?? '').slice(0, 1000);
        const choices = Array.isArray(args.choices) ? args.choices.filter(c => typeof c === 'string' && c.trim()).slice(0, 6).map(c => c.slice(0, 120)) : [];
        const reply = await this.ask(state, 'clarify', { questions: [{ qid: 'answer', question, ...(choices.length ? { choices } : {}) }] }, signal);
        const answer = typeof reply?.answers?.answer === 'string' ? reply.answers.answer.slice(0, 8000) : null;
        if (answer === null) return { content: [{ type: 'text', text: 'The user gave no answer. Do not assume one; continue without it or say what is needed.' }], details: {} };
        // Answers are decisions the rest of the chat relies on; keep them past compaction.
        const answers = state.record.answers ??= [];
        answers.push({ question: question.slice(0, 300), answer: answer.slice(0, 300), at: new Date().toISOString() });
        while (answers.length > 50) answers.shift();
        try { await this.store.save(state.record); } catch { /* The answer still reaches the model. */ }
        return { content: [{ type: 'text', text: `User answered: ${answer}` }], details: {} };
      }
    });
    Object.defineProperty(tools, "batchReads", { value: batchReads });
    return tools;
  }
  get notesFolder() { return path.join(this.home, '..', 'Notes'); }
  noteFile(state) {
    if (!state.record.noteID) return null;
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(state.record.noteID)) throw new Error('Invalid note identity.');
    return path.join(this.notesFolder, `${state.record.noteID}.md`);
  }
  async readNote(state) {
    const file = this.noteFile(state);
    if (!file) return '';
    try { return await readFile(file, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT') return ''; throw error; }
  }
  editNote(state, name, args, callID = null) {
    // The tool scheduler normally runs these sequentially, but restore and
    // concurrent callers must not lose edits or allocate two notes for a chat.
    const write = (state.noteWrite ?? Promise.resolve()).then(() => this.writeNote(state, name, args, callID));
    state.noteWrite = write.catch(() => {});
    return write;
  }
  async writeNote(state, name, args, callID = null) {
    const folder = this.notesFolder;
    await mkdir(folder, { recursive: true, mode: 0o700 });
    if (!state.record.noteID) {
      if (name !== 'note' && name !== 'note_add') return 'There is no note yet: start it with note (its # title and plan).';
      state.record.noteID = randomUUID().toUpperCase();
      await this.store.save(state.record);
    }
    const file = this.noteFile(state);
    const current = await this.readNote(state);
    const receipts = state.record.noteReceipts ??= [];
    const fingerprint = noteHash(JSON.stringify([name, args]));
    const earlier = callID && receipts.find(r => r.id === callID);
    if (earlier && earlier.fingerprint !== fingerprint) throw new Error('Note call identity reused with different arguments.');
    if (earlier?.status === 'done') return earlier.result;
    if (earlier && ![earlier.before, earlier.after].includes(noteHash(current))) throw new Error('Pending note edit conflicts with newer content. Read the note before retrying.');
    const { md, error, note } = earlier ? { md: earlier.markdown } : noteEdits[name](current, args);
    if (error) return error;
    if (Buffer.byteLength(md) > 1024 * 1024) throw new Error('Note exceeds 1 MiB.');
    const receipt = earlier || { id: callID, fingerprint, before: noteHash(current), after: noteHash(md), markdown: md, status: 'started', result: note ? `Saved (${note}).` : 'Saved.' };
    if (callID && !earlier) { receipts.push(receipt); while (receipts.length > 100) receipts.shift(); await this.store.save(state.record); }
    const temp = `${file}.${randomUUID()}.tmp`;
    try {
      await writeFile(temp, md, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
      await rename(temp, file);
    } finally { await rm(temp, { force: true }); }
    if (callID) { receipt.status = 'done'; delete receipt.markdown; await this.store.save(state.record); }
    state.noteChanged = true;
    return receipt.result;
  }
  async clearNotePreview(state) {
    if (state.record.noteID) await rm(path.join(this.notesFolder, `${state.record.noteID}.preview.json`), { force: true });
  }
  previewNote(state, call) {
    const previous = state.notePreviewWrite ?? Promise.resolve();
    state.notePreviewWrite = previous.catch(() => {}).then(async () => {
      if (state.closedNotePreviews?.has(call.id) || !state.running) return;
      if (Date.now() - (state.lastNotePreview ?? 0) < 200) return;
      state.lastNotePreview = Date.now();
      if (!state.record.noteID) {
        if (!['note', 'note_add'].includes(call.name)) return;
        state.record.noteID = randomUUID().toUpperCase(); await this.store.save(state.record);
      }
      const args = Object.fromEntries(Object.entries(call.arguments).filter(([, value]) => typeof value === 'string'));
      let preview;
      try { preview = noteEdits[call.name](await this.readNote(state), args); } catch { return; }
      if (!preview.md || preview.error || Buffer.byteLength(preview.md) > 1024 * 1024) return;
      await saveJSON(path.join(this.notesFolder, `${state.record.noteID}.preview.json`), {
        noteID: state.record.noteID, markdown: preview.md, updatedAt: Date.now()
      });
    }).catch(() => {});
    return state.notePreviewWrite;
  }
  // Every action that can change the world is recorded before and after it runs,
  // keyed by its tool call, so a replayed call returns the earlier receipt
  // instead of acting twice and compaction cannot forget what was done.
  async sideEffect(state, name, args, toolCallID, run) {
    const key = `${state.record.id}:${toolCallID}`;
    const effects = state.record.effects ??= [];
    const earlier = effects.find(effect => effect.key === key);
    if (earlier?.status === 'done') return { content: [{ type: 'text', text: `Already done earlier (${key}): ${earlier.receipt}` }], details: {} };
    if (earlier?.status === 'started') throw new Error('This action may already have run; its outcome is unknown. Check before trying again.');
    const effect = { key, tool: name, target: JSON.stringify(args ?? {}).slice(0, 300), status: 'started', at: new Date().toISOString() };
    effects.push(effect);
    while (effects.length > 200) effects.shift();
    await this.store.save(state.record);
    try {
      const result = await run(key);
      effect.status = 'done';
      effect.receipt = (result?.content ?? []).filter(part => part.type === 'text').map(part => part.text).join(' ').slice(0, 300) || 'ok';
      return result;
    } catch (error) {
      effect.status = 'failed'; effect.receipt = redact(error?.message).slice(0, 300);
      throw error;
    } finally {
      try { await this.store.save(state.record); } catch { /* The started entry keeps the outcome unknown. */ }
    }
  }
  effectsNote(state) {
    const done = (state.record.effects ?? []).filter(effect => effect.status !== 'failed').slice(-40);
    const answers = (state.record.answers ?? []).slice(-20);
    const parts = [];
    if (done.length) parts.push('Side effects already done in this chat. Never redo them; check the receipt first.\n'
      + done.map(effect => `- ${effect.tool} ${effect.target} [${effect.status === 'done' ? 'done' : 'outcome unknown'}] key=${effect.key}${effect.receipt ? ` receipt: ${effect.receipt}` : ''}`).join('\n'));
    if (answers.length) parts.push('Answers the user already gave in this chat. Do not ask again.\n'
      + answers.map(entry => `- Q: ${entry.question} A: ${entry.answer}`).join('\n'));
    return parts.join('\n\n');
  }
  async logStats(state, stats) {
    try {
      const file = path.join(this.home, 'logs', 'turn-stats.jsonl');
      await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
      if ((await stat(file).catch(() => null))?.size > 1024 * 1024) await rename(file, `${file}.1`);
      await appendFile(file, JSON.stringify({ at: new Date().toISOString(), session_id: state.record.id, ...stats }) + '\n', { mode: 0o600 });
    } catch { /* Telemetry never changes the turn outcome. */ }
  }
  async logFailure(state, error) {
    try {
      const file = path.join(this.home, 'logs', 'turn-failures.log');
      await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
      if ((await stat(file).catch(() => null))?.size > 1024 * 1024) await rename(file, `${file}.1`);
      await appendFile(file, JSON.stringify({ at: new Date().toISOString(), session_id: state.record.id,
        error: redact(error?.stack ?? error).slice(0, 4000) }) + '\n', { mode: 0o600 });
    } catch { /* Logging never changes the turn outcome. */ }
  }
  async run(state, text, images, system = '', seed = []) {
    try {
      // One Pi session per chat stays alive across turns. It is rebuilt only
      // when its instructions or tool set change; Brain changes dispose it.
      const tools = await this.tools(state);
      const key = JSON.stringify([system, tools.map(tool => tool.name)]);
      if (!state.session || state.sessionKey !== key) {
        state.session?.dispose(); state.session = null;
        state.session = await this.createSession({ home: this.home, record: state.record, access: this.access,
          tools, system, seed, approve: (name, args, signal) => this.approve(state, name, args, signal),
          sideEffect: (name, args, id, run) => this.sideEffect(state, name, args, id, run),
          previewNote: call => this.previewNote(state, call), effectsNote: () => this.effectsNote(state), stats: stats => this.logStats(state, stats),
          emit: (type, payload) => { if (!(state.noteFinishing && type === 'message.delta')) this.emit(state, type, payload); } });
        state.sessionKey = key;
        await this.store.save(state.record);
      }
      if (state.cancelled) throw new Error('Turn interrupted.');
      state.noteChanged = false; state.closedNotePreviews = new Set();
      await state.session.prompt(text, { images, expandPromptTemplates: false });
      const last = state.session.messages.filter(m => m.role === 'assistant').at(-1);
      const answer = state.session.getLastAssistantText();
      if (state.session.limitReached) throw new Error(state.session.limitReached);
      if (state.cancelled || last?.stopReason === 'aborted') throw new Error('Turn interrupted.');
      if (!answer?.trim() || last?.stopReason === 'error' || last?.stopReason === 'toolUse') throw new Error('No verified final answer.');
      if (state.noteChanged && !state.cancelled && typeof state.session.setActiveToolsByName === 'function') {
        const issues = noteClosingIssues(await this.readNote(state));
        if (issues.length) {
          const active = state.session.getActiveToolNames();
          state.noteFinishing = true;
          this.emit(state, 'agent.thinking', { status: 'Finishing saved note' });
          const cleanupTimer = setTimeout(() => { Promise.resolve(state.session.abort()).catch(() => {}); }, 12000);
          try {
            state.session.setActiveToolsByName(['note_read', ...noteToolDefinitions.map(t => t.name)]);
            await state.session.prompt('Finish the saved note only. Do not perform additional external work or claim unfinished tasks are done. ' + issues.join(' '), { expandPromptTemplates: false });
          } catch { this.emit(state, 'agent.note', { status: 'unfinished', issues }); }
          finally { clearTimeout(cleanupTimer); state.session.setActiveToolsByName(active); state.noteFinishing = false; }
          if (state.cancelled) throw new Error('Turn interrupted.');
          const remaining = noteClosingIssues(await this.readNote(state));
          if (remaining.length) this.emit(state, 'agent.note', { status: 'unfinished', issues: remaining });
        }
      }
      // Restart may restore only this verified native answer, never an arbitrary
      // model stop or note-cleanup response. No action is rerun during recovery.
      if (state.record.activeTurnID) await new StepJournal({ home: this.home, sessionID: state.record.id })
        .checkpointAnswer({ turnID: state.record.activeTurnID, answer });
      state.record.rows.push({ id: state.record.rows.length + 1, role: 'assistant', content: answer, finish_reason: 'stop' });
      state.record.pending = false;
      // Persist the terminal result before announcing completion.
      await this.store.save(state.record);
      this.emit(state, 'message.complete', { status: 'complete', text: answer });
    } catch (error) {
      // Pi records provider failures on the assistant message rather than throwing.
      const last = state.session?.messages?.filter(m => m.role === 'assistant').at(-1);
      const reason = redact(state.session?.limitReached ?? (last?.stopReason === 'error' && last.errorMessage ? last.errorMessage : error?.message)).slice(0, 300);
      if (!state.cancelled) await this.logFailure(state, last?.errorMessage ? `${last.errorMessage}\n${error?.stack ?? error}` : error);
      state.record.pending = false;
      state.record.rows.push({ id: state.record.rows.length + 1, role: 'assistant', content: errorText,
        finish_reason: state.cancelled ? 'aborted' : 'error', display_kind: 'failed_turn', ...(reason && !state.cancelled ? { error_detail: reason } : {}) });
      try { await this.store.save(state.record); } catch { /* Native ledger remains unresolved. */ }
      this.emit(state, 'message.complete', { status: state.cancelled ? 'interrupted' : 'error',
        error: state.cancelled ? 'Turn interrupted.' : reason ? `${errorText} Reason: ${reason}` : errorText });
    } finally {
      await state.notePreviewWrite;
      await this.clearNotePreview(state).catch(() => {});
      state.running = false;
      for (const request of [...state.requests.values()]) request.finish(new Error('Turn ended.'));
    }
  }
  // The runtime starts offline, so its list of a plan's models only grows when
  // asked. Brain asks each time it opens: a newly released model shows up
  // without signing in again. Bounded and at most every ten minutes; offline
  // keeps the list it has.
  async refreshModelCatalog(force = false) {
    const account = speedAccount(await this.access.credentials.read('openai-codex'));
    if (account !== this.catalogAccount) {
      this.catalogAccount = account;
      this.catalogCheckedAt = 0;
      this.modelSpeeds = {};
    }
    if (!force && Date.now() - (this.catalogCheckedAt ?? 0) < 600000) return;
    this.catalogCheckedAt = Date.now();
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 6000);
    try {
      const result = await this.access.runtime.refresh({ allowNetwork: true, force, signal: abort.signal });
      this.catalogWarning = result?.aborted || result?.errors?.size ? 'Some models could not refresh. Showing cached choices.' : null;
      try { this.modelSpeeds = await fetchModelSpeeds(this.access, { signal: abort.signal }); }
      catch { this.modelSpeeds = {}; this.catalogWarning = 'Speed availability could not refresh. Try Refresh models again.'; }
    } catch { this.catalogWarning = 'Models could not refresh. Showing cached choices.'; }
    finally { clearTimeout(timer); }
  }
  async dispatch(peer, method, p = {}) {
    if (method === 'client.capabilities') { peer.serverRequests = p.server_requests === true; return { ok: true }; }
    if (method === 'model.options') {
      await this.refreshModelCatalog(p.refresh === true);
      const config = await readJSON(path.join(this.home, 'model.json'), {});
      const providers = await Promise.all(brainProviders.map(async provider => ({ slug: provider.id,
        name: provider.name, models: this.access.runtime.getModels(provider.id).map(m => m.id),
        efforts: Object.fromEntries(this.access.runtime.getModels(provider.id).map(m => [m.id, modelEfforts(m)])),
        speeds: provider.id === 'openai-codex' ? this.modelSpeeds ?? {} : {},
        model_names: Object.fromEntries(this.access.runtime.getModels(provider.id).map(m => [m.id, m.name ?? m.id])),
        authenticated: await hasBrainCredential(this.access, provider.id), auth_type: provider.auth })));
      return { ...config, providers, catalog_warning: this.catalogWarning ?? null };
    }
    if (method === 'setup.runtime_check') {
      const config = await readJSON(path.join(this.home, 'model.json'), {});
      return { ...config, ok: !!(config.model && await hasBrainCredential(this.access, config.provider)
        && this.access.runtime.getModel(config.provider, config.model)) };
    }
    if (method === 'session.create') {
      if (this.sessions.size >= 128) throw new Error('Session capacity reached. Restart after current work finishes.');
      const record = await this.store.create(p.cwd, p.idempotency_key);
      const state = await this.get(record.id); state.peers.add(peer);
      return this.snapshot(state);
    }
    if (method === 'session.resume') { const state = await this.get(p.session_id); state.peers.add(peer); return this.snapshot(state); }
    if (method === 'mcp.servers.add') {
      if (!validID(p.name) || !path.isAbsolute(p.config?.command) || !Array.isArray(p.config?.args)
        || p.config.args.length !== 1 || !path.isAbsolute(p.config.args[0]) || !p.config.env?.HEYMATE_BRIDGE_CONTEXT_FILE
        || p.config.env?.HEYMATE_SCOPED_ONLY !== '1') throw new Error('Invalid scoped connector.');
      if (this.bridges.has(p.name)) throw new Error('Connector name already attached.');
      const transport = new StdioClientTransport({ command: p.config.command, args: p.config.args,
        env: { PATH: process.env.PATH ?? '/usr/bin:/bin', ...p.config.env }, stderr: 'ignore' });
      const client = new Client({ name: 'heymate-agent', version: '1.0.0' });
      try {
        await client.connect(transport);
        const { tools } = await client.listTools();
        if (!tools?.length || tools.length > 128) throw new Error('No scoped tools available.');
        this.bridges.set(p.name, { client, tools, peer, sessionID: null });
      } catch (error) { await client.close(); throw error; }
      return { ok: true };
    }
    if (method === 'mcp.servers.test') {
      const bridge = this.bridges.get(p.name);
      return { ok: !!bridge && bridge.peer === peer, tools: bridge?.tools.map(t => t.name) ?? [] };
    }
    if (method === 'mcp.servers.remove') {
      const bridge = this.bridges.get(p.name);
      if (bridge && bridge.peer !== peer) throw new Error('Connector ownership mismatch.');
      this.bridges.delete(p.name);
      if (bridge) await bridge.client.close();
      return { ok: true };
    }
    if (method === 'command.dispatch') {
      if (p.name === 'skills' && p.arg === 'pending') return { output: '' };
      throw new Error('No staged skill changes.');
    }
    const state = await this.get(p.session_id);
    if (!state.peers.has(peer)) throw new Error('Resume this session before using it.');
    if (method === 'session.events.since') {
      if (!Number.isSafeInteger(p.last_seen) || p.last_seen < 0) throw new Error('Invalid replay cursor.');
      return { epoch: this.epoch, latest_seq: state.sequence,
        truncated: p.last_seen < (state.events[0]?.seq ?? 1) - 1,
        events: state.events.filter(e => e.seq > p.last_seen), open_requests: [...state.requests.values()].map(r => r.message) };
    }
    if (method === 'reload.mcp') {
      if (state.running) throw new Error('Wait for current work before changing tools.');
      state.bridgeNames.clear();
      for (const [name, bridge] of this.bridges) if (bridge.peer === peer) { bridge.sessionID = state.record.id; state.bridgeNames.add(name); }
      return { status: 'reloaded' };
    }
    if (method === 'image.attach_bytes') {
      // While a turn runs, images may only be attached for a steer message.
      if (state.images.length >= 8 || !boundedText(p.content_base64, 6 * 1024 * 1024)) throw new Error('Invalid image attachment.');
      const mime = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp' }[p.filename?.split('.').at(-1)];
      if (!mime || state.images.reduce((sum, image) => sum + Buffer.from(image.data, 'base64').length, 0)
        + Buffer.from(p.content_base64, 'base64').length > 4 * 1024 * 1024) throw new Error('Image limit exceeded.');
      state.images.push({ type: 'image', data: p.content_base64, mimeType: mime });
      return { attached: true };
    }
    if (method === 'prompt.submit') {
      if (state.running || state.record.pending) throw new Error('Earlier turn requires review; it was not replayed.');
      if (!boundedText(p.text, 262144)) throw new Error('Invalid prompt.');
      if (p.system !== undefined && p.system !== '' && !boundedText(p.system, 65536)) throw new Error('Invalid instructions.');
      if (p.seed !== undefined && !validSeed(p.seed)) throw new Error('Invalid chat history.');
      state.running = true; state.cancelled = false;
      const rowID = state.record.rows.length + 1;
      state.record.rows.push({ id: rowID, role: 'user', content: p.text }); state.record.pending = true;
      state.record.activeTurnID = randomUUID();
      try { await this.store.save(state.record); } catch (error) { state.running = false; throw error; }
      const images = state.images.splice(0);
      // Acceptance is separate from completion; native ledger records this exact row.
      state.run = new Promise(resolve => setImmediate(resolve)).then(() => this.run(state, p.text, images, p.system ?? '', p.seed ?? []));
      return { status: 'streaming', user_row_id: rowID };
    }
    if (method === 'session.steer') {
      // A message sent mid-turn joins the running turn at its next model call
      // instead of cancelling the work already in progress.
      if (!state.running || !state.session?.steer) throw new Error('No running turn to add to. Send it as a new message.');
      const images = state.images.splice(0);
      if (!boundedText(p.text, 65536)) throw new Error('Invalid prompt.');
      await state.session.steer(p.text, images.length ? images : undefined, { source: 'rpc' });
      const rowID = state.record.rows.length + 1;
      state.record.rows.push({ id: rowID, role: 'user', content: p.text, delivery: 'steer' });
      await this.store.save(state.record);
      this.emit(state, 'message.steered', { user_row_id: rowID });
      return { status: 'queued', user_row_id: rowID };
    }
    if (method === 'session.interrupt') {
      state.cancelled = true;
      for (const request of [...state.requests.values()]) request.finish(new Error('Turn interrupted.'));
      await state.session?.abort(); await state.run;
      return { status: 'interrupted' };
    }
    throw new Error('Unsupported HeyMate harness method.');
  }
  async modelSet(p) { return configureBrain(this, p); }
  async messages(id, rowID) {
    const record = await this.store.load(id);
    if (!record) throw new Error('Session not found.');
    if (record.pending) return { messages: [], pagination: { has_newer: true } };
    const rows = record.rows.filter(row => row.id >= rowID);
    return { messages: rows.slice(0, 120), pagination: { has_newer: rows.length > 120 } };
  }
  async close() {
    for (const flow of this.logins.values()) flow.abort?.abort();
    for (const state of this.sessions.values()) {
      state.cancelled = true;
      for (const request of [...state.requests.values()]) request.finish(new Error('Harness stopped.'));
      await state.session?.abort(); await state.run; state.session?.dispose();
    }
    for (const bridge of this.bridges.values()) await bridge.client.close();
  }
}
