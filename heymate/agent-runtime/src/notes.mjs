// A chat's note and the tools that edit it. The note is markdown in HeyMate's Notes folder, drawn by NoteMarkdownView:
// a # title, ## pages, plan boxes ("- [ ] step", the one being worked on ending {now}), options ruled out ending {out},
// tables, and one answer line ("> line {big="…" note="…"}"). The model quotes lines loosely, so edits find their place
// by a line's words when its exact text isn't there. The live preview also runs them on half-streamed arguments, so
// every argument is read as text and a bad one gives an error result, never an exception.

const text = value => (value == null ? '' : String(value));
const MARK = /\s*\{(?:pick|out|new|needs|done|now|gone)\}\s*$/i;
const BOX = /^\s*[-*]\s+\[[ xX]\]/;
const OPEN_BOX = /^\s*[-*]\s+\[ \]/;
const isFence = line => text(line).trim().startsWith('```');

// One blank line between blocks and a newline at the end, but a code block keeps its lines as written.
function tidy(markdown) {
  let source = text(markdown).replace(/\r\n/g, '\n');
  if (!source) return '';
  if (source.endsWith('\n')) source = source.slice(0, -1);
  const kept = [];
  let fenced = false;
  for (const line of source.split('\n')) {
    if (!fenced && line === '' && (!kept.length || kept[kept.length - 1] === '')) continue;
    if (isFence(line)) fenced = !fenced;
    kept.push(line);
  }
  return kept.length ? `${kept.join('\n')}\n` : '';
}
function linesOf(markdown) {
  const lines = tidy(markdown).split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  return lines;
}
const write = lines => tidy(lines.join('\n'));

function kindOf(raw) {
  const line = text(raw), bare = line.trim();
  if (!bare) return 'blank';
  if (/^#{1,6} /.test(bare)) return 'heading';
  if (bare.startsWith('|')) return 'table';
  if (bare.startsWith('```')) return 'fence';
  if (bare === ':::') return 'close';
  if (bare.startsWith(':::')) return 'open';
  if (bare.startsWith('::')) return 'object';
  if (bare.startsWith('>')) return 'quote';
  const indented = /^\s/.test(line);
  if (/^([-*\u2022+]|\d+[.)])\s/.test(bare)) return indented ? 'detail' : 'list';
  return indented ? 'detail' : 'text';
}
// Lines inside a code block are code: a "# comment" there is not a page.
function shape(lines) {
  const fenced = [], held = [];
  let inFence = false, inBlock = false;
  for (const line of lines) {
    fenced.push(inFence);
    held.push(inFence || inBlock);
    const kind = kindOf(line);
    if (kind === 'fence') inFence = !inFence;
    else if (!inFence && kind === 'open') inBlock = true;
    else if (!inFence && kind === 'close') inBlock = false;
  }
  const level = i => (fenced[i] ? 0 : (/^(#{1,6}) /.exec(text(lines[i]).trim())?.[1].length ?? 0));
  return { held, level };
}

// A line's words without its markdown, markers or case: what the model means when it quotes the line.
const keyOf = line => text(line).trim()
  .replace(/(?:\s*\{[^{}]*\})+$/, '')
  .replace(/^(?:#+|>|[-*\u2022+]\s+\[[ xX]\]|[-*\u2022+]|\d+[.)])\s*/, '')
  .replace(/^::+\w+\[?/, '').replace(/\]$/, '')
  .replace(/\*\*|__|`|~~/g, '')
  .replace(/\s+/g, ' ').trim().toLowerCase();
const wordsOf = line => new Set(keyOf(line).split(/[^\p{L}\p{N}$\u20AC\u00A3%.]+/u).filter(word => word.length > 1));

// The line the model meant, from the most to the least certain reading; -1 when nothing is close enough.
function findLine(lines, query, allow = () => true) {
  const wanted = text(query).split('\n').map(line => line.trim()).find(Boolean) ?? '';
  if (!wanted) return -1;
  const pool = lines.map((line, index) => ({ line, index })).filter(({ line, index }) => line.trim() && allow(line, index));
  const key = keyOf(wanted);
  const readings = [
    ({ line }) => line.trim() === wanted,
    key && (({ line }) => keyOf(line) === key),
    ({ line }) => line.includes(wanted),
    key.length >= 4 && (({ line }) => keyOf(line).includes(key)),
  ];
  for (const reading of readings) {
    const hit = reading && pool.find(reading);
    if (hit) return hit.index;
  }
  const words = wordsOf(wanted);
  if (!words.size) return -1;
  let best = -1, bestScore = 0;
  for (const { line, index } of pool) {
    const theirs = wordsOf(line);
    let shared = 0;
    for (const word of words) if (theirs.has(word)) shared++;
    const score = shared / Math.max(words.size, Math.min(theirs.size, words.size * 2));
    if (score > bestScore) [best, bestScore] = [index, score];
  }
  return bestScore >= 0.5 ? best : -1;
}

// Where the block starting at line `at` ends: a page runs to the next page (a # title runs to the first ## page), a
// list item takes its details, a table its rows (unless a row is being added under this one), a block to its close.
function blockEnd(lines, at, adding) {
  const { level } = shape(lines), kind = kindOf(lines[at]), depth = level(at);
  let end = at + 1;
  if (depth) {
    const stop = Math.max(depth, 2);
    while (end < lines.length && !(level(end) && level(end) <= stop)) end++;
    while (end > at + 1 && !lines[end - 1].trim()) end--;
    return end;
  }
  const runWhile = same => { while (end < lines.length && same(kindOf(lines[end]))) end++; return end; };
  if (kind === 'open') return Math.min(runWhile(k => k !== 'close') + 1, lines.length);
  if (kind === 'fence') return Math.min(runWhile(k => k !== 'fence') + 1, lines.length);
  if (kind === 'list') return runWhile(k => k === 'detail');
  if (kind === 'table' && adding !== 'table') return runWhile(k => k === 'table');
  return end;
}

// Blocks are kept a blank line apart, except rows of one table, items of one list and lines of one quote.
const touches = (above, below) => (above === below && ['table', 'list', 'quote', 'detail'].includes(above))
  || (['list', 'detail'].includes(above) && ['list', 'detail'].includes(below));
function insertAt(lines, at, adding) {
  const add = [...adding];
  while (add.length && !add[0].trim()) add.shift();
  while (add.length && !add[add.length - 1].trim()) add.pop();
  if (!add.length) return lines;
  const inBlock = at > 0 && at < lines.length && shape(lines).held[at] && kindOf(lines[at - 1]) !== 'close';
  const above = lines.slice(0, at), below = lines.slice(at);
  const gap = (upper, lower) => upper !== undefined && lower !== undefined && kindOf(upper) !== 'blank' && kindOf(lower) !== 'blank'
    && !inBlock && !touches(kindOf(upper), kindOf(lower));
  return [...above, ...(gap(above[above.length - 1], add[0]) ? [''] : []), ...add,
    ...(gap(add[add.length - 1], below[0]) ? [''] : []), ...below];
}
const pages = lines => { const { level } = shape(lines); return lines.filter((_, i) => level(i)).join(' \u00B7 ') || '(none)'; };
const notFound = (markdown, query, extra = '') => ({ md: markdown, error: `Couldn't find "${text(query).slice(0, 80)}" in the note.${extra}` });

function addTo(markdown, args = {}) {
  let after = text(args.after), md = text(args.md);
  // Some models leak the next parameter into this one as raw tool-call markup.
  const leak = after.indexOf('<parameter name="md">');
  if (leak >= 0) {
    if (!md) md = after.slice(leak + '<parameter name="md">'.length);
    after = after.slice(0, leak).trim();
  }
  if (!md && after.includes('\n')) [md, after] = [after, ''];
  const lines = linesOf(markdown);
  const adding = md.replace(/\r\n/g, '\n').split('\n');
  if (!after.trim()) return { md: write(insertAt(lines, lines.length, adding)) };

  const { level } = shape(lines);
  const toPage = /^#{1,6}\s/.test(after.trim());
  const at = findLine(lines, after, toPage ? (_, i) => level(i) > 0 : undefined);
  if (at < 0) {
    const title = after.replace(/^#+\s*/, '').trim();
    const namesPage = /^##\s/.test(after.trim()) || (title && title.split(' ').length <= 5 && !/[|:>]/.test(title));
    if (!namesPage) return notFound(markdown, after, ` Its headings: ${pages(lines)}`);
    const withPage = insertAt(lines, lines.length, [`## ${title}`]);
    return { md: write(insertAt(withPage, withPage.length, adding)), note: `made a new page "${title}"` };
  }
  const addingKind = kindOf(adding.find(line => line.trim()) ?? '');
  const end = blockEnd(lines, at, addingKind);
  // Rows sent to a page that has a table join its last table, not a new one; a header row means a new table.
  const rowsOnly = adding.filter(line => line.trim()).every(line => kindOf(line) === 'table')
    && !adding.some(line => /^\s*\|[\s:|-]+\|\s*$/.test(line) && line.includes('-'));
  if (level(at) && rowsOnly) {
    let lastRow = -1;
    for (let i = at + 1; i < end; i++) if (kindOf(lines[i]) === 'table') lastRow = i;
    if (lastRow >= 0) return { md: write([...lines.slice(0, lastRow + 1), ...adding.filter(line => line.trim()), ...lines.slice(lastRow + 1)]) };
  }
  return { md: write(insertAt(lines, end, adding)) };
}

function replaceIn(markdown, args = {}) {
  const find = text(args.find), md = text(args.md);
  if (!find) return { md: markdown, error: 'find is empty' };
  const tidied = tidy(markdown), spot = tidied.indexOf(find);
  // Spliced, not String.replace: a "$&" or "$$" in a price must land as typed.
  if (spot >= 0) return { md: tidy(tidied.slice(0, spot) + md + tidied.slice(spot + find.length)) };
  const lines = linesOf(markdown), at = findLine(lines, find);
  if (at < 0) return notFound(markdown, find);
  return { md: write([...lines.slice(0, at), ...(md ? md.split('\n') : []), ...lines.slice(at + 1)]) };
}

function marked(line, mark) {
  const bare = line.replace(MARK, '');
  return kindOf(line) === 'table' ? `${bare.replace(/\s*\|\s*$/, '').replace(MARK, '')} {${mark}} |` : `${bare} {${mark}}`;
}
function removeFrom(markdown, args = {}) {
  const why = text(args.why).trim(), lines = linesOf(markdown), at = findLine(lines, args.find);
  if (at < 0) return notFound(markdown, args.find);
  const kind = kindOf(lines[at]);
  let end = at + 1;
  if (kind === 'list') while (end < lines.length && kindOf(lines[end]) === 'detail') end++;
  // A ruled-out option stays on the page, crossed out; a list item's details give way to the reason.
  if (why && (kind === 'list' || kind === 'table') && !BOX.test(lines[at])) {
    const reason = kind === 'list' ? [`  ${why.replace(/\s*\n\s*/g, ' ')}`] : [];
    return { md: write([...lines.slice(0, at), marked(lines[at], 'out'), ...reason, ...lines.slice(end)]) };
  }
  if (kind === 'open') {
    while (end < lines.length && kindOf(lines[end]) !== 'close') end++;
    end = Math.min(end + 1, lines.length);
  }
  return { md: write([...lines.slice(0, at), ...lines.slice(end)]) };
}

function tick(markdown, args = {}) {
  const lines = linesOf(markdown);
  let at = findLine(lines, args.item, line => OPEN_BOX.test(line));
  if (at < 0) at = findLine(lines, args.item, line => BOX.test(line));
  if (at < 0) {
    const boxes = lines.filter(line => BOX.test(line)).map(keyOf).join(' \u00B7 ') || '(none)';
    return { md: markdown, error: `No plan box like "${text(args.item).slice(0, 60)}". Boxes: ${boxes}` };
  }
  const next = lines.map(line => (BOX.test(line) ? line.replace(/\s*\{now\}\s*$/i, '') : line));
  next[at] = next[at].replace('[ ]', '[x]');
  if (text(args.next)) {
    const now = findLine(next, args.next, line => OPEN_BOX.test(line));
    if (now >= 0) next[now] += ' {now}';
  }
  return { md: write(next) };
}

const attribute = value => text(value).replace(/"/g, "'").replace(/[{}]/g, '').trim();
function answer(markdown, args = {}) {
  const said = text(args.line).replace(/\n/g, ' ').trim();
  if (!said) return { md: markdown, error: 'line is empty' };
  const extras = [args.big && `big="${attribute(args.big)}"`, args.aside && `note="${attribute(args.aside)}"`].filter(Boolean);
  const answerLine = `> ${said}${extras.length ? ` {${extras.join(' ')}}` : ''}`;
  let lines = linesOf(markdown);
  const firstPage = () => { const { level } = shape(lines); return lines.findIndex((_, i) => level(i) === 2); };
  let page = firstPage();
  if (page < 0) {
    const { level } = shape(lines);
    lines = insertAt(lines, lines.findIndex((_, i) => level(i) === 1) + 1, ['## In short']);
    page = firstPage();
  }
  const { level } = shape(lines);
  let end = page + 1;
  while (end < lines.length && level(end) !== 2 && level(end) !== 1) end++;
  const old = lines.slice(page + 1, end).findIndex(line => kindOf(line) === 'quote');
  if (old >= 0) return { md: write(lines.map((line, i) => (i === page + 1 + old ? answerLine : line))) };
  return { md: write(insertAt(lines, page + 1, [answerLine])) };
}

function rewrite(markdown, args = {}) {
  const md = text(args.md);
  return md ? { md: write(linesOf(md)) } : { md: markdown, error: 'md is empty' };
}

// Each edit takes the note's markdown and the call's arguments and returns { md } (with an optional note for the
// model), or { md: unchanged, error } that goes back to the model as the tool result.
export const noteEdits = { note: rewrite, note_add: addTo, note_replace: replaceIn, note_remove: removeFrom, note_tick: tick, note_answer: answer };

const schema = (properties, required) => ({ type: 'object', properties, required, additionalProperties: false });
const field = description => ({ type: 'string', description });
export const noteToolDefinitions = [
  { name: 'note_add',
    description: 'Put new markdown into the note. Give after as a ## heading to append to that page (it is created if absent), as a line '
      + 'already in the note to go straight below it (below a table row means one more row), or as "" to append to the note.',
    parameters: schema({ after: field('where: a ## heading, a line of the note, or "" for the very end'), md: field('markdown to put in') }, ['after', 'md']) },
  { name: 'note_replace',
    description: 'Swap text that is in the note for new text: one figure, a table cell, or a full line.',
    parameters: schema({ find: field('text the note contains now'), md: field('the new text') }, ['find', 'md']) },
  { name: 'note_remove',
    description: 'Take a line out. Passing why keeps a rejected list item or table row visible, struck through, and a list item gets '
      + 'the reason beneath it; with no why the line is simply deleted.',
    parameters: schema({ find: field('the line to take out, or enough of it to pick it'), why: field('reason the option was rejected (optional)') }, ['find']) },
  { name: 'note_tick',
    description: 'Check off a plan box; next can name the box that is now in progress.',
    parameters: schema({ item: field('words of the box to check off'), next: field('words of the box now in progress (optional)') }, ['item']) },
  { name: 'note_answer',
    description: 'Write the answer card shown first on the note (> line {big="…" note="…"}). Calling it again updates the card.',
    parameters: schema({ line: field('the result, said in a single short line'), big: field('headline figure or name, at most 12 characters (optional)'),
      aside: field('small side remark beneath the result (optional)') }, ['line']) },
  { name: 'note',
    description: 'Replace the entire note. Use it to begin one, or to start over when the task changes. After that, prefer the note_ edits: '
      + 'they change only the lines they touch, so the user does not watch finished lines vanish and come back.',
    parameters: schema({ md: field('the full note in markdown: # title, ## pages, plan boxes, tables, answer line') }, ['md']) },
];

export const noteInstructions = `Editing the note:
- note_add(after, md): after="## Budget" appends to the Budget page, creating it at the bottom if needed. after=<a line> places md directly below that line, so after a table row it becomes the following row and after a list item the following item. after="" appends to the whole note.
- note_replace(find, md): change one figure, one cell or one full line in place.
- note_remove(find, why): when you reject an option, pass why so it stays visible, struck through, with the reason; leave why out to delete the line.
- note_tick(item, next): check off a plan box and name the one you move on to.
- note_answer(line, big, aside): the answer card at the head of the note; big is its headline figure or name, aside a small remark beneath.
Organising it:
- Plan boxes list steps only. Results belong on the page they will sit on when the note is finished (a comparison under ## Compare, costs under ## Budget, links under ## Sources and so on), in their final form, never beneath a plan box.
- Compare in one table per question. Write its header once and grow it row by row (after = that page's heading or its bottom row); never start a second table on a page that has one.
These tools return nothing worth waiting for, so keep going in the same turn with your next search or tool call. note.md is only ever changed through these tools, never through write, edit, bash or apply_patch.`;
