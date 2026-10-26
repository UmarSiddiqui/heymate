import path from 'node:path';
import { clampThinkingLevel, getSupportedThinkingLevels } from '@earendil-works/pi-ai';
import { readJSON, saveJSON } from './store.mjs';

// Brain offers exactly three choices: a ChatGPT subscription, a Claude subscription, or a custom API.
export const brainProviders = [
  { id: 'openai-codex', name: 'ChatGPT', auth: 'oauth', preferred: ['gpt-6-sol', 'gpt-5.6-sol'] },
  { id: 'anthropic', name: 'Claude', auth: 'oauth', preferred: ['claude-sonnet-5-5', 'claude-sonnet-5'] },
  { id: 'heymate-custom', name: 'Custom API', auth: 'api_key', preferred: [] },
];
export const brainProvider = id => brainProviders.find(p => p.id === id);
export const brainEfforts = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];
export const modelEfforts = model => getSupportedThinkingLevels(model);
export async function hasBrainCredential(access, id) {
  const provider = brainProvider(id), credential = await access.credentials.read(id);
  return !!provider && credential?.type === provider.auth;
}
function modelID(value) {
  return typeof value === 'string' && value.trim() && value.length <= 256 && !/[\r\n\x00-\x1f]/.test(value) ? value.trim() : null;
}
function customEndpoint(value) {
  const url = new URL(value);
  const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback))
    || url.username || url.password || url.search || url.hash) throw new Error('Invalid API endpoint.');
  return url.href.replace(/\/+$/, '');
}
export async function configureBrain(harness, p) {
  if ([...harness.sessions.values()].some(s => s.running)) throw new Error('Finish current work before changing Brain.');
  const provider = brainProvider(p.provider);
  if (!provider) throw new Error('Unsupported Brain provider.');
  const key = typeof p.api_key === 'string' ? p.api_key.trim() : '';
  if (key.length > 16384 || /[\r\n]/.test(key) || (provider.auth === 'oauth' && key)) throw new Error('Invalid credential.');
  const selectedID = p.model ? modelID(p.model) : null;
  if (p.model && !selectedID) throw new Error('Invalid model.');
  if (p.effort !== undefined && !brainEfforts.includes(p.effort)) throw new Error('Unsupported effort.');
  let custom;
  if (provider.id === 'heymate-custom') {
    if (!selectedID) throw new Error('Enter the API model ID.');
    const endpoint = customEndpoint(p.base_url);
    const api = p.api_format ?? 'openai-completions';
    if (!['openai-completions', 'openai-responses', 'anthropic-messages', 'google-generative-ai'].includes(api)) throw new Error('Unsupported API format.');
    const prior = await readJSON(path.join(harness.home, 'models.json'), { providers: {} });
    // Changing destinations cannot silently reuse a different provider's secret.
    if (prior.providers?.['heymate-custom']?.baseUrl !== endpoint && !key) throw new Error('Enter a key for this API endpoint.');
    custom = { prior, endpoint, api, id: selectedID };
  } else if (selectedID && !harness.access.runtime.getModel(provider.id, selectedID)) {
    throw new Error('Unsupported model for this provider.');
  }
  if (key) await harness.access.credentials.modify(provider.id, async () => ({ type: 'api_key', key }));
  if (!await hasBrainCredential(harness.access, provider.id)) throw new Error('Connect this provider first.');
  if (custom) {
    const entry = { name: 'HeyMate custom API', baseUrl: custom.endpoint, api: custom.api,
      // A custom model is treated as reasoning-capable only when the user asks for effort.
      models: [{ id: custom.id, name: custom.id, reasoning: !!p.effort && p.effort !== 'off', input: ['text'],
        contextWindow: 32768, maxTokens: 4096 }] };
    await saveJSON(path.join(harness.home, 'models.json'), { ...custom.prior,
      providers: { ...custom.prior.providers, 'heymate-custom': entry } });
  }
  if (key || custom) await harness.access.runtime.refresh({ allowNetwork: false });
  const models = harness.access.runtime.getModels(provider.id);
  const current = await readJSON(path.join(harness.home, 'model.json'), {});
  const preferred = provider.preferred;
  const model = selectedID ? harness.access.runtime.getModel(provider.id, selectedID)
    : (current.provider === provider.id && harness.access.runtime.getModel(provider.id, current.model))
      || preferred.map(id => models.find(m => m.id === id)).find(Boolean) || models[0];
  if (!model) throw new Error('No supported chat model available.');
  const requested = p.effort ?? (current.provider === provider.id && current.model === model.id ? current.effort : null) ?? 'medium';
  const effort = clampThinkingLevel(model, requested);
  const config = { provider: provider.id, model: model.id, effort,
    ...(custom ? { base_url: custom.endpoint, api_format: custom.api } : {}) };
  await saveJSON(path.join(harness.home, 'model.json'), config);
  for (const state of harness.sessions.values()) { state.session?.dispose(); state.session = null; }
  return { ok: true, ...config };
}
