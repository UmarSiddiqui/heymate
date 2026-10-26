import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { WebSocketServer, WebSocket } from 'ws';
import { HeyMateHarness } from './harness.mjs';
import { createModelAccess, createPiSession } from './pi-session.mjs';
import { privateHome, validID, readJSON, saveJSON } from './store.mjs';
import { listSkills, skillContent, toggleSkill } from './skills.mjs';

const version = '1.0.0';
const safeError = { error: 'HeyMate harness request failed. Check setup and current task state.' };
export function sameToken(received, expected) {
  return typeof received === 'string' && Buffer.byteLength(received) === Buffer.byteLength(expected)
    && timingSafeEqual(Buffer.from(received), Buffer.from(expected));
}
async function body(request) {
  let bytes = 0; const chunks = [];
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > 1024 * 1024) throw new Error('Request too large.');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}
async function startLogin(harness, provider) {
  if (!['openai-codex', 'anthropic'].includes(provider)) throw new Error('Unsupported subscription.');
  const id = randomUUID(), abort = new AbortController();
  const flow = { abort, provider, status: 'pending' }; harness.logins.set(id, flow);
  let device;
  const announced = new Promise((resolve, reject) => { device = { resolve, reject }; });
  const deadline = setTimeout(() => { abort.abort(); device.reject(new Error('Login start timed out.')); }, 18000);
  flow.task = harness.access.runtime.login(provider, 'oauth', {
    signal: abort.signal,
    prompt: async prompt => {
      if (prompt.type === 'select' && prompt.options.some(o => o.id === 'device_code')) return 'device_code';
      if (prompt.type === 'select' && provider === 'anthropic') return 'copy_code';
      if (prompt.type === 'manual_code' && provider === 'anthropic') {
        return await new Promise((resolve, reject) => {
          flow.answer = resolve;
          abort.signal.addEventListener('abort', () => reject(new Error('Sign-in cancelled.')), { once: true });
        });
      }
      throw new Error('This sign-in requires an unsupported interaction.');
    },
    notify: event => {
      if (event.type === 'auth_url' && provider === 'anthropic') {
        const url = new URL(event.url);
        if (url.origin !== 'https://claude.ai' || url.pathname !== '/oauth/authorize') {
          abort.abort(); device.reject(new Error('Unexpected sign-in page.')); return;
        }
        clearTimeout(deadline);
        device.resolve({ session_id: id, flow: 'authorization_code', verification_url: url.href, expires_in: 900, poll_interval: 3 });
      }
      if (event.type === 'device_code' && provider === 'openai-codex') {
        clearTimeout(deadline);
        const url = new URL(event.verificationUri);
        if (url.origin !== 'https://auth.openai.com' || url.pathname !== '/codex/device' || url.search || url.hash) {
          abort.abort(); device.reject(new Error('Unexpected sign-in page.')); return;
        }
        device.resolve({ session_id: id, flow: 'device_code', user_code: event.userCode,
          verification_url: url.href, expires_in: Math.min(event.expiresInSeconds ?? 900, 900),
          poll_interval: Math.min(30, Math.max(3, event.intervalSeconds ?? 5)) });
      }
    }
  }, { agentName: 'HeyMate', getDeviceId: () => harness.deviceID }).then(async () => {
    await harness.access.runtime.refresh({});
    await harness.modelSet({ provider });
    flow.status = 'approved';
  }).catch(() => { flow.status = abort.signal.aborted ? 'expired' : 'error'; device.reject(new Error('Sign-in failed.')); })
    .finally(() => clearTimeout(deadline));
  flow.expiry = setTimeout(() => { if (flow.status === 'pending') abort.abort(); harness.logins.delete(id); }, 900000);
  flow.expiry.unref();
  try { return await announced; }
  catch (error) { abort.abort(); harness.logins.delete(id); throw error; }
}

export async function startServer({ home, token, access, createSession = createPiSession, port = 0, commit = null }) {
  if (!token || token.length < 32) throw new Error('An owner token is required.');
  home = await privateHome(home);
  const harness = new HeyMateHarness({ home, access: access ?? await createModelAccess(home), createSession });
  const identityFile = path.join(home, 'device.json');
  const identity = await readJSON(identityFile, null) ?? { id: randomUUID() };
  await saveJSON(identityFile, identity); harness.deviceID = identity.id;
  const server = http.createServer(async (request, response) => {
    response.setHeader('Content-Type', 'application/json'); response.setHeader('Cache-Control', 'no-store');
    const send = (status, value) => { response.writeHead(status); response.end(JSON.stringify(value)); };
    if (request.headers.origin || !sameToken(request.headers['x-heymate-agent-token'], token)) return send(401, { error: 'Unauthorized.' });
    try {
      const url = new URL(request.url, 'http://127.0.0.1');
      const method = request.method;
      if (method === 'GET' && url.pathname === '/api/host/identity') return send(200, {
        ok: true, protocolVersion: 1, pid: process.pid, servesSpa: false, role: 'desktop-serve', engine: 'pi' });
      if (method === 'GET' && url.pathname === '/api/health') return send(200, { ok: true, version, commit });
      if (method === 'GET' && url.pathname === '/api/status') return send(200, { version, agent_home: home, engine: 'pi' });
      if (method === 'GET' && url.pathname === '/api/config') return send(200, { model: await readJSON(path.join(home, 'model.json'), {}), engine: 'pi' });
      if (method === 'POST' && url.pathname === '/api/model/set') return send(200, await harness.modelSet(await body(request)));
      if (method === 'GET' && url.pathname === '/api/skills') return send(200, await listSkills(home));
      if (method === 'GET' && url.pathname === '/api/skills/content') return send(200, { content: await skillContent(home, url.searchParams.get('name')) });
      if (method === 'PUT' && url.pathname === '/api/skills/toggle') {
        const p = await body(request);
        if (typeof p.enabled !== 'boolean' || [...harness.sessions.values()].some(s => s.running)) throw new Error('Invalid skill change.');
        await toggleSkill(home, p.name, p.enabled); return send(200, { ok: true });
      }
      const start = url.pathname.match(/^\/api\/providers\/oauth\/(openai-codex|anthropic)\/start$/);
      if (method === 'POST' && start) return send(200, await startLogin(harness, start[1]));
      const submit = url.pathname.match(/^\/api\/providers\/oauth\/sessions\/([A-Za-z0-9_-]+)\/code$/);
      if (method === 'POST' && submit) {
        const flow = harness.logins.get(submit[1]);
        const input = await body(request);
        if (flow?.provider !== 'anthropic' || flow.status !== 'pending' || !flow.answer
          || typeof input.code !== 'string' || !input.code.trim() || input.code.length > 8192) throw new Error('Invalid sign-in code.');
        flow.answer(input.code.trim()); flow.answer = null;
        return send(200, { ok: true });
      }
      const poll = url.pathname.match(/^\/api\/providers\/oauth\/(openai-codex|anthropic)\/poll\/([A-Za-z0-9_-]+)$/);
      if (method === 'GET' && poll) {
        const flow = harness.logins.get(poll[2]);
        if (!flow || flow.provider !== poll[1]) return send(404, safeError);
        return send(200, { session_id: poll[2], status: flow.status });
      }
      const cancel = url.pathname.match(/^\/api\/providers\/oauth\/sessions\/([A-Za-z0-9_-]+)$/);
      if (method === 'DELETE' && cancel) {
        const flow = harness.logins.get(cancel[1]); flow?.abort.abort();
        await flow?.task; clearTimeout(flow?.expiry); harness.logins.delete(cancel[1]); return send(200, { ok: true });
      }
      const messages = url.pathname.match(/^\/api\/sessions\/([A-Za-z0-9_-]+)\/messages\/around$/);
      if (method === 'GET' && messages) {
        const row = Number(url.searchParams.get('row_id'));
        if (!Number.isSafeInteger(row) || row < 1) throw new Error('Invalid row.');
        return send(200, await harness.messages(messages[1], row));
      }
      send(404, { error: 'Unsupported route.' });
    } catch { send(400, safeError); }
  });
  server.headersTimeout = 10000; server.requestTimeout = 30000;
  const sockets = new WebSocketServer({ noServer: true, maxPayload: 8 * 1024 * 1024 });
  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (request.headers.origin || url.pathname !== '/api/ws' || !sameToken(url.searchParams.get('token'), token)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return;
    }
    sockets.handleUpgrade(request, socket, head, ws => sockets.emit('connection', ws));
  });
  sockets.on('connection', ws => {
    let inFlight = 0;
    const peer = { serverRequests: false, open: () => ws.readyState === WebSocket.OPEN,
      send: message => {
        const data = JSON.stringify(message);
        if (Buffer.byteLength(data) > 2 * 1024 * 1024 || ws.bufferedAmount > 4 * 1024 * 1024) { ws.close(1009); return; }
        if (ws.readyState === WebSocket.OPEN) ws.send(data);
      } };
    peer.send({ jsonrpc: '2.0', method: 'event', params: { type: 'gateway.ready', payload: { replay_epoch: harness.epoch } } });
    ws.on('message', async bytes => {
      let message;
      try {
        message = JSON.parse(bytes.toString());
        if (message.jsonrpc !== '2.0' || typeof message !== 'object') throw new Error('Invalid RPC.');
        if (!message.method) { harness.answer(peer, message); return; }
        if (++inFlight > 128 || typeof message.method !== 'string' || message.params && typeof message.params !== 'object') throw new Error('Request limit.');
        const result = await harness.dispatch(peer, message.method, message.params);
        if (message.id !== undefined) peer.send({ jsonrpc: '2.0', id: message.id, result });
      } catch {
        if (message?.id !== undefined) peer.send({ jsonrpc: '2.0', id: message.id,
          error: { code: -32000, message: safeError.error } });
        else ws.close(1008);
      } finally { inFlight = Math.max(0, inFlight - 1); }
    });
    ws.on('error', () => {}); ws.on('close', () => harness.disconnect(peer));
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return { port: server.address().port, harness, async close() {
    await harness.close(); for (const ws of sockets.clients) ws.terminate();
    await new Promise(resolve => sockets.close(resolve)); await new Promise(resolve => server.close(resolve));
  } };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
    const manifest = await readJSON(path.join(root, 'manifest.json'), {});
    const app = await startServer({ home: process.env.HEYMATE_AGENT_HOME,
      token: process.env.HEYMATE_AGENT_DASHBOARD_SESSION_TOKEN, commit: manifest.sourceCommit ?? null });
    process.stdout.write(`HEYMATE_AGENT_BACKEND_READY port=${app.port}\n`);
    let stopping = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
      if (stopping) return; stopping = true;
      await app.close(); process.exit(0);
    });
  } catch { process.stderr.write('HeyMate agent could not start. Check its runtime and private profile.\n'); process.exitCode = 1; }
}
