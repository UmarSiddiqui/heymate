import { brainProviders, hasBrainCredential, configureBrain, modelEfforts } from './brain.mjs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { readFile, readdir, realpath } from 'node:fs/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { SessionStore, validID, readJSON, saveJSON } from './store.mjs';

const boundedText = (value, max) => typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= max;
const errorText = 'HeyMate could not finish this operation. Check model access or retry after reviewing progress.';

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
    return new Promise((resolve, reject) => {
      const finish = (error, value) => {
        if (!state.requests.delete(id)) return;
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
    for (const name of state.bridgeNames) {
      const bridge = this.bridges.get(name);
      if (!bridge || bridge.sessionID !== state.record.id) continue;
      for (const tool of bridge.tools) {
        tools.push({ name: `${name}_${tool.name}`, label: tool.name, description: tool.description || tool.name,
          parameters: tool.inputSchema,
          execute: async (_id, args, signal) => {
            signal?.throwIfAborted();
            if (this.bridges.get(name) !== bridge || !state.running) throw new Error('Connector scope expired.');
            // The native scoped bridge enforces current-turn action approvals too.
            const result = await bridge.client.callTool({ name: tool.name, arguments: args }, undefined, { signal });
            if (result.isError) throw new Error('Connector action failed. Inspect returned tool evidence before reporting success.');
            return { content: result.content ?? [], details: {} };
          }
        });
      }
    }
    tools.push({ name: 'ask_user', label: 'Ask a question', description: 'Ask one short bundled set of questions when required facts are missing.',
      parameters: { type: 'object', properties: { question: { type: 'string' } }, required: ['question'], additionalProperties: false },
      execute: async (_id, args, signal) => {
        const answer = await this.ask(state, 'clarify', { questions: [{ qid: 'answer', question: args.question }] }, signal);
        return { content: [{ type: 'text', text: JSON.stringify(answer?.answers ?? {}) }], details: {} };
      }
    });
    return tools;
  }
  async run(state, text, images) {
    try {
      state.session?.dispose();
      state.session = await this.createSession({ home: this.home, record: state.record, access: this.access,
        tools: await this.tools(state), approve: (name, args, signal) => this.approve(state, name, args, signal),
        emit: (type, payload) => this.emit(state, type, payload) });
      await this.store.save(state.record);
      if (state.cancelled) throw new Error('Turn interrupted.');
      await state.session.prompt(text, { images, expandPromptTemplates: false });
      const last = state.session.messages.filter(m => m.role === 'assistant').at(-1);
      const answer = state.session.getLastAssistantText();
      if (state.cancelled || last?.stopReason === 'aborted') throw new Error('Turn interrupted.');
      if (!answer?.trim() || last?.stopReason === 'error' || last?.stopReason === 'toolUse') throw new Error('No verified final answer.');
      state.record.rows.push({ id: state.record.rows.length + 1, role: 'assistant', content: answer, finish_reason: 'stop' });
      state.record.pending = false;
      // Persist the terminal result before announcing completion.
      await this.store.save(state.record);
      this.emit(state, 'message.complete', { status: 'complete', text: answer });
    } catch {
      state.record.pending = false;
      state.record.rows.push({ id: state.record.rows.length + 1, role: 'assistant', content: errorText,
        finish_reason: state.cancelled ? 'aborted' : 'error', display_kind: 'failed_turn' });
      try { await this.store.save(state.record); } catch { /* Native ledger remains unresolved. */ }
      this.emit(state, 'message.complete', { status: state.cancelled ? 'interrupted' : 'error', error: state.cancelled ? 'Turn interrupted.' : errorText });
    } finally {
      state.running = false;
      for (const request of [...state.requests.values()]) request.finish(new Error('Turn ended.'));
    }
  }
  async dispatch(peer, method, p = {}) {
    if (method === 'client.capabilities') { peer.serverRequests = p.server_requests === true; return { ok: true }; }
    if (method === 'model.options') {
      const config = await readJSON(path.join(this.home, 'model.json'), {});
      const providers = await Promise.all(brainProviders.map(async provider => ({ slug: provider.id,
        name: provider.name, models: this.access.runtime.getModels(provider.id).map(m => m.id),
        efforts: Object.fromEntries(this.access.runtime.getModels(provider.id).map(m => [m.id, modelEfforts(m)])),
        model_names: Object.fromEntries(this.access.runtime.getModels(provider.id).map(m => [m.id, m.name ?? m.id])),
        authenticated: await hasBrainCredential(this.access, provider.id), auth_type: provider.auth })));
      return { ...config, providers };
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
      if (state.running || state.images.length >= 8 || !boundedText(p.content_base64, 6 * 1024 * 1024)) throw new Error('Invalid image attachment.');
      const mime = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp' }[p.filename?.split('.').at(-1)];
      if (!mime || state.images.reduce((sum, image) => sum + Buffer.from(image.data, 'base64').length, 0)
        + Buffer.from(p.content_base64, 'base64').length > 4 * 1024 * 1024) throw new Error('Image limit exceeded.');
      state.images.push({ type: 'image', data: p.content_base64, mimeType: mime });
      return { attached: true };
    }
    if (method === 'prompt.submit') {
      if (state.running || state.record.pending) throw new Error('Earlier turn requires review; it was not replayed.');
      if (!boundedText(p.text, 262144)) throw new Error('Invalid prompt.');
      state.running = true; state.cancelled = false;
      const rowID = state.record.rows.length + 1;
      state.record.rows.push({ id: rowID, role: 'user', content: p.text }); state.record.pending = true;
      try { await this.store.save(state.record); } catch (error) { state.running = false; throw error; }
      const images = state.images.splice(0);
      // Acceptance is separate from completion; native ledger records this exact row.
      state.run = new Promise(resolve => setImmediate(resolve)).then(() => this.run(state, p.text, images));
      return { status: 'streaming', user_row_id: rowID };
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
