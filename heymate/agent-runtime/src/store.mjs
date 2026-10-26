import { mkdir, readFile, open, rename, realpath, chmod } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export const validID = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value);
export async function readJSON(file, fallback) {
  try { return JSON.parse(await readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}
export async function saveJSON(file, value) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  const handle = await open(temporary, 'wx', 0o600);
  try { await handle.writeFile(JSON.stringify(value)); await handle.sync(); }
  finally { await handle.close(); }
  await rename(temporary, file);
  const directory = await open(path.dirname(file), 'r');
  try { await directory.sync(); } finally { await directory.close(); }
}
export async function privateHome(home) {
  if (!home || !path.isAbsolute(home)) throw new Error('An absolute private agent home is required.');
  const canonical = await realpath(home);
  await chmod(canonical, 0o700);
  return canonical;
}

export class SessionStore {
  constructor(home) { this.root = path.join(home, 'desktop', 'sessions'); }
  file(id) {
    if (!validID(id)) throw new Error('Invalid session identity.');
    return path.join(this.root, `${id}.json`);
  }
  async create(cwd, id = randomUUID()) {
    if (!path.isAbsolute(cwd)) throw new Error('An absolute workspace is required.');
    const existing = await this.load(id);
    if (existing) {
      if (existing.cwd !== await realpath(cwd)) throw new Error('Workspace identity mismatch.');
      return existing;
    }
    const record = { id, cwd: await realpath(cwd), sessionFile: null, rows: [], pending: false };
    await this.save(record);
    return record;
  }
  load(id) { return readJSON(this.file(id), null); }
  save(record) { return saveJSON(this.file(record.id), record); }
}
