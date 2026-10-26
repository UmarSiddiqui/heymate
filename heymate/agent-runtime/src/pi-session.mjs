import { hasBrainCredential } from './brain.mjs';
import path from 'node:path';
import { createAgentSession, createCodingTools, DefaultResourceLoader,
  ModelRuntime, SessionManager, SettingsManager } from '@earendil-works/pi-coding-agent';
import { readJSON } from './store.mjs';
import { FileCredentials } from './credentials.mjs';
import { skillPrompt } from './skills.mjs';

export async function createModelAccess(home) {
  const credentials = new FileCredentials(path.join(home, 'auth.json'));
  const runtime = await ModelRuntime.create({ credentials, modelsPath: path.join(home, 'models.json'),
    modelsStorePath: path.join(home, 'models-cache.json'), allowModelNetwork: false });
  return { credentials, runtime };
}

// HeyMate owns the tool boundary. No discovered extensions, global Pi settings,
// shell startup files or third-party MCP inventories enter this session.
export async function createPiSession({ home, record, access, tools, approve, emit }) {
  const config = await readJSON(path.join(home, 'model.json'), {});
  if (!config.model || !await hasBrainCredential(access, config.provider)) {
    throw new Error('Choose a plan or API provider and model in Brain first.');
  }
  const model = access.runtime.getModel(config.provider, config.model);
  if (!model) throw new Error('The selected model is unavailable. Choose a supported model.');
  const settings = SettingsManager.inMemory({ autoCompaction: { enabled: true }, retry: { enabled: true } });
  const enabledSkills = await skillPrompt(home);
  const loader = new DefaultResourceLoader({ cwd: record.cwd, agentDir: home, settingsManager: settings,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    systemPrompt: 'You are HeyMate, a personal assistant in a native macOS app. Do authorized work, use tools, verify outcomes, and report failures honestly. Ask before irreversible external actions. Never claim an action succeeded from a plan or tool discovery. Follow the current mate identity supplied by the host.\n\n' + enabledSkills });
  await loader.reload();
  const builtins = createCodingTools(record.cwd).map(tool => ({
    ...tool, label: tool.name,
    execute: async (id, params, signal, onUpdate) => {
      signal?.throwIfAborted();
      // All shell commands require approval: shell text is not a reliable read/write classifier.
      if (tool.name !== 'read') await approve(tool.name, params, signal);
      signal?.throwIfAborted();
      return tool.execute(id, params, signal, onUpdate);
    }
  }));
  const manager = record.sessionFile
    ? SessionManager.open(record.sessionFile, path.join(home, 'sessions'), record.cwd)
    : SessionManager.create(record.cwd, path.join(home, 'sessions'));
  const { session } = await createAgentSession({ cwd: record.cwd, agentDir: home,
    modelRuntime: access.runtime, model, thinkingLevel: config.effort ?? 'medium', settingsManager: settings, sessionManager: manager,
    resourceLoader: loader, noTools: 'builtin', customTools: [...builtins, ...tools] });
  record.sessionFile = manager.getSessionFile();
  session.subscribe(event => {
    if (event.type === 'message_update' && event.assistantMessageEvent?.type === 'text_delta') {
      emit('message.delta', { text: event.assistantMessageEvent.delta });
    } else if (event.type === 'tool_execution_start') {
      emit('tool.start', { name: event.toolName, tool_call_id: event.toolCallId });
    } else if (event.type === 'tool_execution_end') {
      emit('tool.end', { name: event.toolName, tool_call_id: event.toolCallId, is_error: event.isError });
    }
  });
  return session;
}
