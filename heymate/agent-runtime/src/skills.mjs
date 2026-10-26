import path from 'node:path';
import { readFile, readdir, realpath } from 'node:fs/promises';
import { readJSON, saveJSON } from './store.mjs';

const validName = name => typeof name === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(name);
export async function skillContent(home, name) {
  if (!validName(name)) throw new Error('Invalid skill name.');
  const root = path.join(home, 'skills');
  const file = await realpath(path.join(root, name, 'SKILL.md'));
  if (!file.startsWith(root + path.sep)) throw new Error('Skill escapes private profile.');
  const text = await readFile(file, 'utf8');
  if (Buffer.byteLength(text) > 262144) throw new Error('Skill exceeds size limit.');
  return text;
}
export async function listSkills(home) {
  let entries;
  try { entries = await readdir(path.join(home, 'skills'), { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  if (entries.length > 2000) throw new Error('Skill count exceeds limit.');
  const settings = await readJSON(path.join(home, 'settings.json'), {});
  const skills = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !validName(entry.name)) continue;
    const text = await skillContent(home, entry.name);
    skills.push({ name: entry.name, description: /^description:\s*(.+)$/m.exec(text)?.[1] ?? '',
      enabled: (settings.enabledSkills ?? []).includes(entry.name) });
  }
  return skills;
}
export async function toggleSkill(home, name, enabled) {
  await skillContent(home, name);
  const file = path.join(home, 'settings.json'), settings = await readJSON(file, {});
  const names = new Set(settings.enabledSkills ?? []);
  enabled ? names.add(name) : names.delete(name);
  await saveJSON(file, { ...settings, enabledSkills: [...names] });
}
export async function skillPrompt(home) {
  const snippets = [];
  for (const skill of await listSkills(home)) {
    if (skill.enabled) snippets.push(`Skill ${skill.name}:\n${await skillContent(home, skill.name)}`);
  }
  const text = snippets.join('\n\n');
  if (Buffer.byteLength(text) > 65536) throw new Error('Enabled skills exceed context limit. Disable unused skills.');
  return text;
}
