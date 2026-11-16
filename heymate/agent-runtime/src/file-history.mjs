// Per-file history for mate folders, kept at the write/edit tool boundary.
// Before a mate turn's write or edit changes an existing file inside a mate
// folder, the current bytes are saved; when write creates a new file, it is
// recorded as made by the mate. HeyMate's Files view reads the same records
// (MateFileStore.swift), so the on-disk format is shared:
//   <root>/<key>/origins.jsonl          one JSON event per line
//   <root>/<key>/versions/index.json    {"files": {"<relative path>": [{id, at, size, source}]}}, oldest first
//   <root>/<key>/versions/blobs/<id>
// key = first 16 hex characters of sha256(realpath(mate folder)). A mate
// folder is a direct child of HEYMATE_MATES_ROOT. Paths outside it are ignored.
import { createHash, randomUUID } from 'node:crypto';
import { appendFile, copyFile, lstat, mkdir, readFile, realpath, rename, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export const historyLimits = { perFile: 10, maxFileBytes: 5 * 1024 * 1024, maxTotalBytes: 200 * 1024 * 1024 };

export function folderKey(realFolder) {
  return createHash('sha256').update(realFolder).digest('hex').slice(0, 16);
}

// Newest `perFile` per file, then oldest across the mate until the total fits.
export function pruneIndex(index, limits = historyLimits) {
  const files = {};
  const removed = [];
  for (const [file, versions] of Object.entries(index.files ?? {})) {
    const kept = versions.slice(-limits.perFile);
    removed.push(...versions.slice(0, versions.length - kept.length).map(version => version.id));
    if (kept.length) files[file] = kept;
  }
  let total = Object.values(files).flat().reduce((sum, version) => sum + (version.size ?? 0), 0);
  if (total > limits.maxTotalBytes) {
    const oldest = Object.entries(files).flatMap(([file, versions]) => versions.map(version => [file, version]))
      .sort((a, b) => a[1].at === b[1].at ? (a[1].id < b[1].id ? -1 : 1) : (a[1].at < b[1].at ? -1 : 1));
    for (const [file, version] of oldest) {
      if (total <= limits.maxTotalBytes) break;
      files[file] = files[file].filter(entry => entry.id !== version.id);
      if (!files[file].length) delete files[file];
      removed.push(version.id);
      total -= version.size ?? 0;
    }
  }
  return { index: { files }, removed };
}

export function createFileHistory({ root, matesRoot, limits = historyLimits, now = () => new Date() }) {
  let queue = Promise.resolve();
  const serial = work => { const next = queue.then(work, work); queue = next.catch(() => {}); return next; };

  // Resolves symlinks and `..` the way the write tool will, then finds the
  // mate folder (a direct child of matesRoot) that contains the target.
  async function locate(target) {
    let base = path.resolve(target);
    const tail = [];
    for (;;) {
      try { await lstat(base); break; } catch {
        const parent = path.dirname(base);
        if (parent === base) return null;
        tail.unshift(path.basename(base));
        base = parent;
      }
    }
    let real, rootReal;
    try { real = await realpath(base); rootReal = await realpath(matesRoot); } catch { return null; }
    const resolved = path.join(real, ...tail);
    const relative = path.relative(rootReal, resolved);
    if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) return null;
    const [slug, ...rest] = relative.split(path.sep);
    if (!rest.length) return null;
    const folder = path.join(rootReal, slug);
    return { file: resolved, relative: rest.join('/'), store: path.join(root, folderKey(folder)) };
  }

  async function snapshot(place, source) {
    let info;
    try { info = await stat(place.file); } catch { return false; }
    if (!info.isFile()) return true;
    if (info.size > limits.maxFileBytes) return true;
    const versions = path.join(place.store, 'versions');
    const id = randomUUID();
    await mkdir(path.join(versions, 'blobs'), { recursive: true });
    await copyFile(place.file, path.join(versions, 'blobs', id));
    const indexFile = path.join(versions, 'index.json');
    let index = { files: {} };
    try { index = JSON.parse(await readFile(indexFile, 'utf8')); } catch { /* first version */ }
    (index.files ??= {})[place.relative] ??= [];
    index.files[place.relative].push({ id, at: now().toISOString(), size: info.size, source });
    const pruned = pruneIndex(index, limits);
    const temporary = `${indexFile}.${process.pid}.${id}.tmp`;
    await writeFile(temporary, JSON.stringify(pruned.index));
    await rename(temporary, indexFile);
    await Promise.all(pruned.removed.map(old => rm(path.join(versions, 'blobs', old), { force: true })));
    return true;
  }

  return {
    // Returns what after() needs. Never throws into the tool call.
    before: target => serial(async () => {
      const place = await locate(target).catch(() => null);
      if (!place) return null;
      const existed = await snapshot(place, 'mate').catch(() => true);
      return { place, existed };
    }),
    after: state => serial(async () => {
      if (!state?.place || state.existed) return;
      try { if (!(await stat(state.place.file)).isFile()) return; } catch { return; }
      await mkdir(state.place.store, { recursive: true });
      await appendFile(path.join(state.place.store, 'origins.jsonl'),
        JSON.stringify({ path: state.place.relative, origin: 'mate', at: now().toISOString() }) + '\n', { mode: 0o600 });
    }).catch(() => {})
  };
}

export function fileHistoryFromEnv(env = process.env) {
  const root = env.HEYMATE_FILE_HISTORY_DIR, matesRoot = env.HEYMATE_MATES_ROOT;
  return root && matesRoot && path.isAbsolute(root) && path.isAbsolute(matesRoot) ? createFileHistory({ root, matesRoot }) : null;
}

// Wraps one write or edit tool call. Other tools pass straight through.
export async function withFileHistory(history, cwd, name, params, run) {
  if (!history || !['write', 'edit'].includes(name) || typeof params?.path !== 'string') return run();
  const raw = params.path.startsWith('~/') || params.path === '~' ? path.join(os.homedir(), params.path.slice(1)) : params.path;
  const state = await history.before(path.resolve(cwd, raw)).catch(() => null);
  const result = await run();
  if (!result?.isError) await history.after(state);
  return result;
}
