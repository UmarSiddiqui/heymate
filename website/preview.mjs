// Local preview with the same stats handler as Vercel. No build or dependencies.
import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import handler from './api/stats.mjs';
import { brotliCompressSync, gzipSync } from 'node:zlib';
const root = fileURLToPath(new URL('.', import.meta.url));
const types = { '.html':'text/html; charset=utf-8', '.css':'text/css', '.js':'text/javascript', '.mjs':'text/javascript', '.webp':'image/webp', '.png':'image/png', '.jpg':'image/jpeg', '.svg':'image/svg+xml', '.txt':'text/plain', '.md':'text/markdown; charset=utf-8', '.woff2':'font/woff2', '.mp4':'video/mp4', '.vtt':'text/vtt; charset=utf-8', '.xml':'application/xml; charset=utf-8' };
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/_vercel/insights/script.js') { res.writeHead(200, { 'Content-Type':'text/javascript' }); return res.end('// Analytics disabled in local preview.'); }
  if (url.pathname === '/api/stats') { res.status = code => { res.statusCode = code; return res; }; res.json = data => { res.setHeader('Content-Type','application/json'); res.end(JSON.stringify(data)); }; return handler(req,res); }
  try {
    let name = decodeURIComponent(url.pathname);
    if (name === '/') name = '/index.html';
    const full = path.resolve(root, '.' + name);
    if (!full.startsWith(root) || full.includes('/.') || /\.(mjs|test\.js)$/.test(full) || (path.extname(full) === '.md' && !['index.md', 'connect-claude-codex.md', 'screen-guidance.md'].includes(path.basename(full)) && !full.startsWith(path.join(root, 'blog') + path.sep))) { res.writeHead(404); return res.end(); }
    let file = full;
    try { if ((await stat(file)).isDirectory()) file = path.join(file, 'index.html'); } catch { if (!path.extname(file)) file += '.html'; }
    const data = await readFile(file);
    const headers = { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store', 'Vary': 'Accept-Encoding' };
    // Match Vercel's compressed text delivery for realistic local performance checks.
    const encoding = req.headers['accept-encoding'] || '';
    let body = data;
    if (/\.(html|css|js|txt|md|svg|xml)$/.test(file)) {
      if (/\bbr\b/.test(encoding)) { headers['Content-Encoding'] = 'br'; body = brotliCompressSync(data); }
      else if (/\bgzip\b/.test(encoding)) { headers['Content-Encoding'] = 'gzip'; body = gzipSync(data); }
    }
    res.writeHead(200, headers); res.end(body);
  } catch { res.writeHead(404); res.end('Not found'); }
}).listen(4173,'127.0.0.1',() => console.log('HeyMate preview: http://127.0.0.1:4173'));
