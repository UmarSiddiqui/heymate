import test from 'node:test';
import assert from 'node:assert/strict';
import { noteEdits, noteInstructions, noteToolDefinitions } from '../src/notes.mjs';

const edit = (md, name, args) => noteEdits[name](md, args);
const start = '# Laptop for Sam\n\n## In short\n- [ ] Compare models {now}\n- [ ] Decide\n\n## Compare\n| Model | Price |\n| --- | --- |\n| Air | $999 |\n';

test('a note fills in through the small edits', () => {
  let md = edit('', 'note', { md: start }).md;
  const steps = [
    ['note_add', { after: '## Compare', md: '| Pro | $1,599 |' }],
    ['note_add', { after: 'Budget', md: '- Under $1,200' }],
    ['note_remove', { find: 'pro', why: 'Over budget' }],
    ['note_tick', { item: 'compare the models', next: 'Decide' }],
    ['note_answer', { line: 'Get the Air', big: '$999', aside: 'Fits the budget' }],
    ['note_replace', { find: '$999 |', md: '$949 |' }],
  ];
  const notes = [];
  for (const [name, args] of steps) {
    const result = edit(md, name, args);
    assert.equal(result.error, undefined, name);
    if (result.note) notes.push(result.note);
    md = result.md;
  }
  assert.deepEqual(notes, ['made a new page "Budget"']);
  assert.equal(md, '# Laptop for Sam\n\n## In short\n\n> Get the Air {big="$999" note="Fits the budget"}\n\n'
    + '- [x] Compare models\n- [ ] Decide {now}\n\n## Compare\n| Model | Price |\n| --- | --- |\n| Air | $949 |\n'
    + '| Pro | $1,599 {out} |\n\n## Budget\n\n- Under $1,200\n');
});

test('edits find the line the model meant, and say so when they cannot', () => {
  const md = '# Trip\n\n## Hotels\n- **Hotel Alpha** by the river\n  quiet rooms\n- Hotel Beta\n';
  assert.equal(edit(md, 'note_remove', { find: 'hotel alpha by the river', why: 'Sold out' }).md,
    '# Trip\n\n## Hotels\n- **Hotel Alpha** by the river {out}\n  Sold out\n- Hotel Beta\n');
  assert.equal(edit(md, 'note_remove', { find: '- Hotel Beta' }).md, '# Trip\n\n## Hotels\n- **Hotel Alpha** by the river\n  quiet rooms\n');
  assert.equal(edit(md, 'note_add', { after: 'Hotel Beta', md: '- Hotel Gamma' }).md.endsWith('- Hotel Beta\n- Hotel Gamma\n'), true);
  const missing = edit(md, 'note_add', { after: 'a sentence that is nowhere in it', md: 'x' });
  assert.equal(missing.md, md);
  assert.match(missing.error, /Couldn't find .* Its headings: # Trip · ## Hotels/);
  assert.match(edit(md, 'note_tick', { item: 'Book' }).error, /No plan box like "Book". Boxes: \(none\)/);
});

test('a table page gets new rows under its table, and a header row starts a new table', () => {
  const md = '## Compare\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter the table.\n';
  assert.equal(edit(md, 'note_add', { after: '## Compare', md: '| 3 | 4 |' }).md,
    '## Compare\n| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\nAfter the table.\n');
  assert.equal(edit(md, 'note_add', { after: '## Compare', md: '| C | D |\n| - | - |' }).md,
    '## Compare\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter the table.\n\n| C | D |\n| - | - |\n');
});

test('replacement text lands as typed, even with $ patterns', () => {
  assert.equal(edit('Price: $10\n', 'note_replace', { find: '$10', md: '$$10 or $& off' }).md, 'Price: $$10 or $& off\n');
});

test('code blocks keep their lines and are not read as pages', () => {
  assert.equal(edit('', 'note', { md: '# T\n\n```py\na = 1\n\n\nb = 2\n```\n\n\n\nend' }).md, '# T\n\n```py\na = 1\n\n\nb = 2\n```\n\nend\n');
  const setup = '# Repo\n\n## Setup\n```bash\n# install deps\nnpm ci\n```\n\n## Next\n- ship\n';
  assert.equal(edit(setup, 'note_add', { after: '## Setup', md: 'Then run the tests.' }).md,
    '# Repo\n\n## Setup\n```bash\n# install deps\nnpm ci\n```\n\nThen run the tests.\n\n## Next\n- ship\n');
  assert.equal(edit('# Repo\n\n```md\n## not a page\n```\n', 'note_answer', { line: 'Done' }).md,
    '# Repo\n\n## In short\n\n> Done\n\n```md\n## not a page\n```\n');
});

test('the answer line replaces the last answer and keeps its markers well formed', () => {
  const md = '# T\n\n## In short\n> Old answer\n- [ ] Step\n';
  assert.equal(edit(md, 'note_answer', { line: 'New\nanswer', big: 'say "hi" {x}', aside: 'aside' }).md,
    '# T\n\n## In short\n> New answer {big="say \'hi\' x" note="aside"}\n- [ ] Step\n');
  assert.equal(edit(md, 'note_answer', { line: ' ' }).error, 'line is empty');
});

test('arguments of any type and every half-streamed prefix give a result, never an exception', () => {
  const md = '# T\n\n## P\n- [ ] 3\n| 10 | 4 |\n';
  assert.equal(edit(md, 'note_replace', { find: 10, md: 12 }).md, '# T\n\n## P\n- [ ] 3\n| 12 | 4 |\n');
  assert.equal(edit(md, 'note_tick', { item: 3 }).md, '# T\n\n## P\n- [x] 3\n| 10 | 4 |\n');
  for (const [name, args] of [['note_add', { after: 5, md: 7 }], ['note_remove', { find: 4 }], ['note', { md: 9 }], ['note_answer', {}], ['note_add', undefined]])
    assert.equal(typeof edit(md, name, args).md, 'string', name);
  const call = { after: '## Compare', md: '| Pro | $1,599 |\n| Max | $2,499 |' };
  for (let i = 0; i <= call.md.length; i++) {
    const result = edit(start, 'note_add', { ...call, md: call.md.slice(0, i) });
    assert.equal(typeof result.md, 'string');
    assert.ok(result.md.startsWith('# Laptop for Sam\n'));
  }
});

test('a leaked md parameter in after is read as md', () => {
  assert.equal(edit('# T\n\n## P\ntext\n', 'note_add', { after: '## P <parameter name="md">more', md: '' }).md, '# T\n\n## P\ntext\n\nmore\n');
});

test('the tools keep their names and arguments, and the instructions name each of them', () => {
  assert.deepEqual(noteToolDefinitions.map(tool => [tool.name, Object.keys(tool.parameters.properties), tool.parameters.required]), [
    ['note_add', ['after', 'md'], ['after', 'md']],
    ['note_replace', ['find', 'md'], ['find', 'md']],
    ['note_remove', ['find', 'why'], ['find']],
    ['note_tick', ['item', 'next'], ['item']],
    ['note_answer', ['line', 'big', 'aside'], ['line']],
    ['note', ['md'], ['md']],
  ]);
  for (const tool of noteToolDefinitions) {
    assert.equal(tool.parameters.additionalProperties, false);
    assert.ok(tool.description.length > 20);
    if (tool.name !== 'note') assert.ok(noteInstructions.includes(`${tool.name}(`), tool.name);
  }
  assert.equal(Object.keys(noteEdits).sort().join(), noteToolDefinitions.map(tool => tool.name).sort().join());
});
