// Speed eligibility belongs to the signed-in account, never a hard-coded model list.
export const speedNames = { default: 'Standard', priority: 'Fast', fast: 'Fast', ultrafast: 'Ultrafast' };
export function catalogSpeeds(catalog) {
  const result = {};
  for (const model of catalog.models ?? []) {
    if (typeof model.slug !== 'string') continue;
    const tiers = (model.service_tiers ?? []).map(tier => tier.id);
    // Older catalogs advertise Fast through additional_speed_tiers.
    if (!tiers.includes('priority') && !tiers.includes('fast') && model.additional_speed_tiers?.includes('fast')) tiers.push('priority');
    const supported = ['default', ...tiers.filter(id => Object.hasOwn(speedNames, id) && id !== 'default')];
    result[model.slug] = [...new Set(supported)];
  }
  return result;
}
export function speedAccount(credential) {
  if (credential?.type !== 'oauth' || !credential.access) return null;
  try {
    const claims = JSON.parse(Buffer.from(credential.access.split('.')[1], 'base64url').toString());
    return claims['https://api.openai.com/auth']?.chatgpt_account_id ?? null;
  } catch { return null; }
}
export async function fetchModelSpeeds(access, { signal, fetcher = fetch } = {}) {
  if (!await access.credentials.read('openai-codex')) return {};
  // Let Pi refresh OAuth credentials under its normal credential lock.
  await access.runtime.getAuth('openai-codex', { signal });
  const credential = await access.credentials.read('openai-codex');
  if (credential?.type !== 'oauth' || !credential.access) return {};
  const account = speedAccount(credential);
  if (!account) return {};
  const response = await fetcher('https://chatgpt.com/backend-api/codex/models?client_version=0.144.0', {
    headers: { Authorization: `Bearer ${credential.access}`, 'ChatGPT-Account-Id': account }, signal
  });
  if (!response.ok) throw new Error('ChatGPT speed catalog unavailable.');
  return catalogSpeeds(await response.json());
}
export function applyModelSpeed(payload, config, model) {
  if (config.provider !== 'openai-codex' || model.api !== 'openai-codex-responses') return payload;
  return { ...payload, service_tier: config.speed ?? 'default' };
}
