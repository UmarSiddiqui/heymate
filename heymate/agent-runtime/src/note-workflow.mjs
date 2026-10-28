import { createHash } from 'node:crypto';
export const noteHash = text => createHash('sha256').update(text).digest('hex');
export function noteClosingIssues(markdown) {
  if (!markdown.trim()) return [];
  const issues = [];
  if (!/^>\s+\S/m.test(markdown)) issues.push('Add a short answer line summarizing the actual result, including any blockers.');
  if (/\{now\}/.test(markdown)) issues.push('Remove current-work markers from stopped work; leave genuinely unfinished checklist items unchecked and explain what remains.');
  const fences = markdown.split('\n').filter(line => /^\s*```/.test(line)).length;
  if (fences % 2) issues.push('Close the unfinished code fence.');
  return issues;
}
export function notePreviewCall(event) {
  const update = event.assistantMessageEvent;
  if (!update || !['toolcall_delta', 'toolcall_end'].includes(update.type)) return null;
  const call = update.toolCall ?? update.partial?.content?.[update.contentIndex];
  if (call?.type !== 'toolCall' || !['note', 'note_add', 'note_replace', 'note_remove', 'note_tick', 'note_answer'].includes(call.name)) return null;
  if (!call.arguments || typeof call.arguments !== 'object') return null;
  // Pi's parser supplies partial arguments; freeze them before the stream mutates.
  return { id: call.id, name: call.name, arguments: structuredClone(call.arguments) };
}
