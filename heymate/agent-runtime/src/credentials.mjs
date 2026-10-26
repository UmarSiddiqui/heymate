import { writeFile } from 'node:fs/promises';
import lockfile from 'proper-lockfile';
import { readJSON, saveJSON } from './store.mjs';

// The app owns storage; Pi owns provider login/refresh protocols. Serialize
// refresh and login across processes so rotated OAuth tokens cannot race.
export class FileCredentials {
  constructor(file) { this.file = file; }
  async read(provider, options = {}) { options.signal?.throwIfAborted(); return (await readJSON(this.file, {}))[provider]; }
  async list(options = {}) {
    options.signal?.throwIfAborted();
    return Object.entries(await readJSON(this.file, {})).map(([providerId, value]) => ({ providerId, type: value.type }));
  }
  async transaction(action, options) {
    options?.signal?.throwIfAborted();
    try { await writeFile(this.file, '{}', { flag: 'wx', mode: 0o600 }); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    const release = await lockfile.lock(this.file, { realpath: false, retries: { retries: 20, minTimeout: 100, maxTimeout: 500 } });
    try {
      options?.signal?.throwIfAborted();
      const values = await readJSON(this.file, {});
      const result = await action(values);
      options?.signal?.throwIfAborted();
      await saveJSON(this.file, values);
      return result;
    } finally { await release(); }
  }
  modify(provider, action, options) {
    return this.transaction(async values => {
      const credential = await action(values[provider]);
      if (credential !== undefined) values[provider] = credential;
      return values[provider];
    }, options);
  }
  delete(provider, options) { return this.transaction(async values => { delete values[provider]; }, options); }
}
