// Editorial source. Rebuild HTML and Markdown with: node website/scripts/build-blog.mjs
import { launchPost } from './launch-post.mjs';
const p = text => ({ type: 'paragraph', text });
const list = (...items) => ({ type: 'list', items });
const steps = (...items) => ({ type: 'steps', items });
const prompt = text => ({ type: 'prompt', text });
const section = (title, ...blocks) => ({ title, blocks });
const table = (headers, rows) => ({ type: 'table', headers, rows });
const image = (src, alt, width, height, caption) => ({ type: 'image', src, alt, width, height, caption });

export const posts = [
launchPost,
{
 slug: 'learn-mac-apps-with-ai', category: 'Workflows', topic: 'Learning apps',
 title: 'Learn a Mac app with AI guidance, one step at a time',
 description: 'Use HeyMate to understand an unfamiliar Mac app, ask for one step at a time, and check what you learned without leaving your work.',
 answer: 'HeyMate can explain the app in front of you, point to a control, and wait while you try it. It fits learning tasks where you want to understand the interface rather than delegate the entire job.',
 related: ['ai-study-tutor-mac', 'heymate-vs-apple-shortcuts', 'choose-open-source-ai-assistant-mac'],
 sections: [
 section('Start with one result you can check',
 p('An unfamiliar app becomes easier to learn when your first task is small. Instead of asking for a tour of every menu, choose an outcome: export a sample document, change one layer, or find a setting. Keep a copy of the original so you can compare the result without worrying about losing your work.'),
 p('HeyMate supplies context from the current screen to the vision-capable provider you choose. That can help when a written tutorial shows a different version of an app. The model can still misread the screen; the useful habit is to check each suggested control before clicking.')),
 section('Try a guided practice session',
 steps('Open the app with a sample file and bring the relevant window to the front.', 'Hold Control + Option and describe the result you want.', 'Ask HeyMate to explain one step, point to the control, and wait.', 'Do the step yourself. Say “next” or use the indicated target when the walkthrough is ready to continue.', 'When the result appears, describe what changed and ask how to verify it.'),
 prompt('I am new to this app. Show me how to export this sample as a PDF. Explain one step at a time and wait while I try it. If a control is unclear, ask me before guessing.')),
 section('Turn the answer into a skill',
 p('After completing the task, repeat it without guidance. Write down the two or three controls that mattered. Then ask a follow-up about the reason behind a choice: why this export format, which setting affects quality, or when you would use another option. This keeps the exercise about learning the software rather than memorizing a string of clicks.'),
 prompt('Quiz me on what I just did. Ask one question at a time, then give me a similar task with a different sample file. Do not do the clicking for me.')),
 section('When a tutorial or manual is the better route',
 p('Use the app’s official documentation when you need authoritative feature names, supported formats, or version-specific behavior. A structured course may be better for learning a whole discipline. HeyMate is useful for questions that arise in the middle of practice; it is not a substitute for the software vendor’s reference material.'),
 p('If the answer refers to a button that is not present, stop and describe the difference. Do not keep advancing through a plan that no longer matches the screen. Refreshing context can help, but it does not establish that the next answer is correct.')),
 section('Set up screen access deliberately',
 p('You need macOS 14.2 or later and a vision-capable provider. [Connect Claude or ChatGPT through Codex](/connect-claude-codex), then review [macOS permissions](/permissions). Optional Apple Intelligence in HeyMate is text-only and cannot see the screen.'),
 p('Use sample content until you understand the data path: relevant screen context goes to the selected provider. A walkthrough can capture again between steps. See [screen guidance](/screen-guidance) and [privacy details](/privacy) before using confidential material.'))
 ]
},
{
 slug: 'ai-design-review-figma', category: 'Workflows', topic: 'Design',
 title: 'Use HeyMate for a focused Figma or website design review',
 description: 'Ask for actionable design feedback on hierarchy, copy, spacing, and contrast. Turn a screen-aware AI critique into a small revision you can compare.',
 answer: 'HeyMate can discuss a visible design and point out what it means. Use it for a focused critique, then verify measurements and accessibility with design and browser tools.',
 related: ['learn-mac-apps-with-ai', 'visual-explanations-on-mac', 'heymate-vs-raycast'],
 sections: [
 section('Give the critique a real brief',
 p('“Make this look better” leaves too much to guess. State who the page serves, what the user should do next, and what you are allowed to change. A checkout, documentation page, and portfolio need different kinds of feedback. Bring the frame or live page into view and ask about the most important part first.'),
 prompt('This page helps first-time visitors download a Mac app. Review the visible hierarchy and wording. Give me three changes, ranked by impact. Point to each element you mean. Keep the existing typeface and brand colors.')),
 section('Review in separate passes',
 list('Hierarchy: can a reader identify the main message and next action?', 'Wording: do labels describe a concrete action or hide behind vague language?', 'Layout: do spacing and alignment group related content?', 'Accessibility: which elements need a measured contrast or keyboard check?'),
 p('Treat the critique as a set of hypotheses. Ask why each change supports the user’s goal, and reject suggestions that ignore constraints such as brand guidelines or a component library. A smaller set of specific changes is easier to evaluate than a complete redesign.')),
 section('Make one revision and compare',
 steps('Duplicate the frame or use a safe branch of the page.', 'Apply one suggested change yourself, or approve a tightly scoped task if you want computer control.', 'Compare the original and revision at the same size.', 'Check the page at a narrow viewport and with longer real copy.', 'Keep the change only if you can explain the improvement.'),
 prompt('Compare the current version with the goal I gave you. Did this change make the next action clearer? Name one remaining issue and one part I should leave alone.')),
 section('Measure what a screenshot cannot establish',
 p('A screen image does not prove the exact contrast ratio, DOM reading order, keyboard focus behavior, responsive breakpoints, or screen-reader output. Use an accessibility checker and keyboard testing for those checks. HeyMate can help you understand the results on screen, but a visual opinion is not an accessibility certification.'),
 p('For Figma work, inspect the actual spacing and typography values rather than copying measurements guessed from pixels. For a website, test the rendered page. The same design can behave differently with real content, browser zoom, or a different font load.')),
 section('Keep client work and permissions in view',
 p('Relevant screen images go to your selected AI provider. Use a sample frame or approved project material, and read the [privacy explanation](/privacy). Connected app access is separate from simply looking at a Figma window; it depends on the tools and accounts you configure.'),
 p('Start with the [screen guidance walkthrough](/screen-guidance). For broader software practice, see [learning a Mac app with AI](/blog/learn-mac-apps-with-ai). Results depend on the model and the context it can actually see.'))
 ]
},
{
 slug: 'explain-terminal-errors-with-ai', category: 'Workflows', topic: 'Development',
 title: 'Understand terminal errors with HeyMate before changing code',
 description: 'Use screen-aware AI to read an error, form a testable hypothesis, and plan a small fix. Includes prompts, secret handling, and verification steps.',
 answer: 'HeyMate can explain a visible terminal error and help you decide what evidence to collect next. When you want code changed, use a scoped agent task, review its plan, and verify the result with a relevant test.',
 related: ['heymate-vs-claude-cowork', 'choose-open-source-ai-assistant-mac', 'ai-weekly-research-brief'],
 sections: [
 section('Ask for an explanation before a command',
 p('A terminal failure often contains several messages, and the last line may be a consequence rather than the cause. Begin by asking which line matters and what it actually establishes. Keep the failing command, the working directory, and the first relevant error visible. Remove tokens, private URLs, and customer data from anything you share.'),
 prompt('Explain this error using only the visible output. Separate facts from guesses. What is the smallest read-only check that would distinguish the two most likely causes? Do not run or suggest a destructive command.')),
 section('Build a short debugging loop',
 steps('Reproduce the error with the smallest command or input you can.', 'Ask what the output proves and what information is missing.', 'Run a relevant diagnostic that you understand.', 'Update the hypothesis using the new output.', 'Change one thing, then rerun the command or focused test.'),
 p('This approach works whether the failure is a missing tool, a dependency mismatch, or a test assertion. The point is not to guess the right fix immediately. It is to make each next action produce evidence that narrows the problem. A plausible explanation without a reproduction remains a guess.')),
 section('Turn the investigation into an approved coding task',
 prompt('In this project, fix the failing test we just discussed. First show a read-only plan naming the files you expect to change, the reason for the change, and the test you will run. Do not change dependencies or unrelated formatting.'),
 p('HeyMate can hand work to configured coding providers. Use Claude Code or Codex when the task needs shell commands to build or test itself; HeyMate’s OpenCode jobs can edit files but cannot run shell commands. Provider capabilities and access rules differ. Review the proposed scope before approving execution.')),
 section('Verify behavior, not just a clean log',
 p('A passing command is useful only if it checks the behavior that failed. Confirm the original trigger, a normal case, and any boundary exposed by the bug. Inspect the diff for unrelated changes. If the result depends on a remote service, distinguish a successful local test from a verified production fix.'),
 p('Workspace snapshots can support local undo, but they cannot unsend a message or reverse a remote service change. Approved work may continue in a background helper after the app quits. Choose the project folder carefully and check job status before starting a second attempt.')),
 section('Use the right source for the exact error',
 p('Check the tool’s official documentation when an error concerns a command flag, supported runtime, or provider limit. HeyMate can help interpret that documentation in context. It does not turn model memory into an authoritative version-specific reference.'),
 p('Start with [provider setup](/connect-claude-codex) and [screen guidance](/screen-guidance). Review [privacy](/privacy) before showing logs: screen context can leave your Mac through the provider connection you select.'))
 ]
},
{
 slug: 'organize-files-with-ai-on-mac', category: 'Workflows', topic: 'Files',
 title: 'Organize Mac files with AI: plan first, move second',
 description: 'Use HeyMate to draft a file organization plan, preview renames, and review small batches. Includes duplicate handling and verification prompts.',
 answer: 'HeyMate can help plan file organization and hand an approved task to tools with the access you configure. Start with an inventory and a proposed change list; a filename alone does not establish that a file is safe to delete.',
 related: ['heymate-vs-alfred', 'heymate-vs-apple-shortcuts', 'explain-terminal-errors-with-ai'],
 sections: [
 section('Define what “organized” means',
 p('A folder can be tidy and still be hard to use. Choose a rule that helps your next task: group invoices by year, collect assets by project, or separate exports from source files. Name the one folder in scope. Keep a backup or work on a sample copy before trying an agent on files that matter.'),
 prompt('Inspect only this sample folder. Propose a folder structure and a table of current paths and proposed paths. Do not move, rename, overwrite, or delete anything yet. Flag ambiguous items for my review.')),
 section('Review the proposed paths',
 list('Keep original file extensions and identify filename collisions.', 'Ask for the rule used for dates instead of assuming a filename contains the creation date.', 'Separate exact duplicates from files that merely look similar.', 'Leave uncertain items unchanged and list the question needed to place them.', 'Keep a record of the original path for every proposed change.'),
 p('A useful plan should be understandable without running it. If the agent cannot explain why an item belongs in a destination, a catch-all “review” folder may be better than a confident guess. Do not mix a cleanup with an unrelated change to permissions, synchronization, or cloud storage.')),
 section('Approve a small batch',
 prompt('Apply only the ten renames I approved. Do not overwrite existing files. Stop on a collision or missing file. Report every completed move and every skipped item, with original and new paths.'),
 p('The tools available depend on the provider and integrations you connect. A Finder screenshot can support discussion, but it is not a complete inventory of nested folders. Use a configured file tool or coding job when the task needs an actual listing. Review the plan before granting broader access.')),
 section('Verify before considering deletion',
 steps('Compare the reported changes with the approved list.', 'Open a few moved files and confirm their content is intact.', 'Check that project references or linked assets still resolve.', 'Keep the change log and backup while you use the new structure.', 'Handle deletion as a separate decision, after reviewing actual file contents or verified duplicate evidence.'),
 p('HeyMate’s workspace snapshots support some local undo flows, not universal recovery across every folder or connected service. A remote move, synchronized deletion, or external action can have effects outside the local workspace. Do not treat an undo button as a replacement for a backup.')),
 section('Choose a simpler tool when the rule is fixed',
 p('If you repeatedly apply the same known transformation, an explicit automation or file-search workflow may be easier to inspect and maintain. Read [HeyMate versus Apple Shortcuts](/blog/heymate-vs-apple-shortcuts) and [HeyMate versus Alfred](/blog/heymate-vs-alfred) for those tradeoffs.'),
 p('Before working on private files, review [what leaves your Mac](/privacy). HeyMate is open source, but connected AI providers and services have their own processing and retention rules.'))
 ]
},
{
 slug: 'ai-weekly-research-brief', category: 'Workflows', topic: 'Research',
 title: 'Build a weekly research brief with a specialist HeyMate',
 description: 'Create a research mate with a clear topic, source rules, and a reviewable output. Includes a recurring brief prompt and checks for unsupported claims.',
 answer: 'A specialist mate can keep a recurring research role and instructions. The useful result is a sourced brief that distinguishes new evidence, interpretation, and missing information—not a confident summary with unverified links.',
 related: ['ai-meeting-prep-mac', 'heymate-vs-claude-cowork', 'choose-open-source-ai-assistant-mac'],
 sections: [
 section('Write a brief for the researcher',
 p('Define the question before choosing the schedule. “Watch competitors” is too broad. A more useful scope names the products, the kinds of changes that matter, and the period to compare. Specify whether you want releases, pricing changes, documentation updates, or customer announcements, and which sources count as evidence.'),
 prompt('Create a research mate for changes to the three products I name. Prefer official release notes and product documentation. For each finding, include the source URL, publication date when available, what changed, and why it might matter. Mark anything you could not verify.')),
 section('Make the output easy to audit',
 list('Scope and period: what the brief covers and which dates it compares.', 'Confirmed changes: short findings with direct sources.', 'Implications: clearly labeled analysis rather than vendor claims.', 'Open questions: missing pages, inaccessible sources, or conflicting information.', 'Next actions: decisions a person should review, not automatic external changes.'),
 p('Do a one-off run before creating a routine. Open the linked pages and check whether they actually support the claims. A recent crawl date is not always the date of an event. Ask the mate to distinguish “newly found” from “newly announced” so old documentation does not become a false product launch.')),
 section('Then add a recurring routine',
 p('HeyMate mates can have scheduled routines. Start with the cadence controls available in your version, such as daily at a chosen time or every N hours. Write the intended period into the task so each run has a clear boundary. Check the first few outputs before relying on the routine.'),
 prompt('For each research run, compare with the previous brief if it is available. Do not repeat an unchanged item as new. If nothing material changed, say so briefly. Do not contact vendors, publish, or change files outside the agreed workspace.'),
 p('Research depends on the provider’s tools and the integrations you configure. If a run has no browser or source access, it should report that limitation rather than imply a fresh search. A recurring schedule does not give an agent new permissions or make a model’s knowledge current.')),
 section('Keep interpretation separate from evidence',
 p('A feature launch does not prove adoption, product quality, or revenue. Ask for the exact evidence behind business implications. If the brief is intended for a client or team, review the sources yourself before sharing. Use a stable format so missing dates and unsupported comparisons stand out instead of being hidden by polished prose.'),
 p('For a meeting-focused version, see [meeting preparation](/blog/ai-meeting-prep-mac). For a tool choice, see [HeyMate versus Claude Cowork](/blog/heymate-vs-claude-cowork), including where the products overlap.')),
 section('Understand background work and cost',
 p('Enabled routines and approved jobs can run in the background. That is different from an app that acts only while you hold a hotkey. Provider limits and optional connector fees still apply, even though HeyMate adds no subscription fee. Review [privacy and storage](/privacy) and use only the accounts and sources you intend to expose.'))
 ]
},
{
 slug: 'draft-email-with-ai-on-mac', category: 'Workflows', topic: 'Writing',
 title: 'Draft better email on Mac with HeyMate and a review step',
 description: 'Turn rough notes into a focused email draft, check its claims, and keep sending separate from drafting. Includes reusable prompts for tone and edits.',
 answer: 'Use HeyMate to understand the visible context, discuss a response, or work with an email integration you configure. Drafting and sending should remain separate decisions, especially when the message makes a commitment.',
 related: ['ai-meeting-prep-mac', 'heymate-vs-raycast', 'heymate-vs-alfred'],
 sections: [
 section('Give the draft a purpose and boundaries',
 p('Start with what the recipient needs to know or do. State the relationship, the desired tone, and the facts that must remain exact. If you are replying to a thread, check which messages and attachments the model can actually access. A visible screen is only part of a conversation, and an integration has only the permissions you grant it.'),
 prompt('Draft a reply to the context I provide. Goal: agree on a meeting time without promising a delivery date. Use a warm, direct tone and fewer than 120 words. Preserve names and dates exactly. If a necessary fact is missing, ask instead of inventing it. Do not send.')),
 section('Use voice for rough thoughts, then edit for the reader',
 p('Hold Control + Option to explain what you want to say in your own words. An unstructured spoken note can be a useful first input because it preserves your priorities. Then ask for a concise version with the request near the beginning. Read the result aloud; remove phrases that do not sound like something you would write.'),
 prompt('Keep my meaning but remove repetition. Put the requested action first. List any factual claims or commitments you added that were not present in my notes.'),
 p('For repeated replies, save a clear template or use a dedicated text-expansion tool. Asking a model to regenerate an unchanged address or standard paragraph adds uncertainty without adding much value. [The Alfred comparison](/blog/heymate-vs-alfred) explains when snippets are a better fit.')),
 section('Check the risky details yourself',
 list('Recipient and reply-all list: confirm the actual destination.', 'Names, dates, amounts, links, and attachments: compare with the source.', 'Commitments: identify promises, approvals, deadlines, or concessions.', 'Tone: remove implied blame or urgency you did not intend.', 'Context: confirm that the draft does not reveal private details from another thread.'),
 p('A polished draft can still contain an unsupported statement. Asking for a separate fact check is useful, but it is not independent evidence if the model is checking its own invented detail. Compare the draft against the original notes and correspondence.')),
 section('Sending needs its own decision',
 p('If you connect an email service, its capabilities depend on the configured tools and account access. Do not assume a draft has been saved or sent because the assistant described it. Check the service’s draft or sent view, and approve the actual destination and content before an external send.'),
 p('HeyMate’s local undo cannot unsend an email or reverse another remote service change. Keep your first experiment to sample content. Read [privacy details](/privacy) before sharing a real thread; the selected provider receives the context it processes.')),
 section('Build a reusable editing habit',
 p('A writing mate can hold preferences such as “short paragraphs,” “ask before making promises,” and “always list unknown facts.” Those instructions are useful across tasks, but they do not replace a final read. If your need is a one-press rewrite in a launcher, [Raycast may also fit](/blog/heymate-vs-raycast). Choose the interaction that makes review easiest for you.'))
 ]
},
{
 slug: 'ai-meeting-prep-mac', category: 'Workflows', topic: 'Planning',
 title: 'Prepare for meetings on Mac with a source-backed AI brief',
 description: 'Use HeyMate to turn approved notes and connected app context into a meeting agenda, open questions, and follow-ups you can verify.',
 answer: 'HeyMate can help assemble a meeting brief from the notes, files, and connected tools you make available. Keep source-backed facts separate from suggested questions, and review any calendar or message action before it happens.',
 related: ['ai-weekly-research-brief', 'draft-email-with-ai-on-mac', 'heymate-vs-claude-cowork'],
 sections: [
 section('Start with the meeting decision',
 p('A useful brief answers why the meeting exists, not just who is attending. Specify the decision to reach, the people involved, and which documents are in scope. If the agent cannot access a calendar or file, provide the relevant facts yourself or connect the service deliberately; do not let missing access become a fabricated agenda.'),
 prompt('Prepare a brief for the meeting described in these approved notes. Include the decision we need, confirmed background with source references, unresolved questions, and a proposed agenda. Separate facts from suggestions. Do not message attendees or change calendar events.')),
 section('Use a brief small enough to read',
 list('Purpose: one sentence describing the decision or outcome.', 'Confirmed background: only facts tied to an accessible source.', 'Open questions: points that could change the decision.', 'Proposed agenda: a realistic order for discussing those questions.', 'Follow-up candidates: drafts for review, with no assumed owners or deadlines.'),
 p('Ask for the exact document, message, or note behind each important claim. A link to a whole folder is less useful than a source that identifies the relevant passage. If your notes disagree, keep both versions and name the conflict. Do not quietly merge them into a confident but unsupported statement.')),
 section('Connect only what the task needs',
 p('HeyMate supports Apple apps and configurable integrations through local tools, MCP servers, and Composio. Availability depends on your setup and the connected service. Calendar access does not automatically imply email access, and local notes are not the same as a complete history of decisions.'),
 p('For a first run, use a sample agenda and a small set of approved documents. A specialist mate can keep the role and output format for future meetings. If you create a recurring routine, remember that enabled routines and approved work can run in the background. Review the cadence and account access, not just the quality of the first brief.')),
 section('Check before and after the meeting',
 steps('Read the brief against the original sources and correct missing context.', 'Remove private material that attendees should not receive.', 'Use the proposed questions to prepare your own notes.', 'Afterward, record actual decisions instead of treating pre-meeting suggestions as agreed actions.', 'Approve recipients, owners, and dates before any follow-up is sent or scheduled.'),
 prompt('Turn these meeting notes into draft follow-ups. Label each item as a decision, an open question, or a proposed action. Do not assign an owner or due date unless the notes state one.')),
 section('Know what this workflow does not establish',
 p('A prepared brief does not mean HeyMate recorded, transcribed, or attended the meeting. Do not assume those capabilities from this example. The workflow is about context you provide or make available through configured tools. Provider limits, connector access, and retention rules still apply.'),
 p('Read [privacy and storage](/privacy), then use the [email drafting workflow](/blog/draft-email-with-ai-on-mac) for a reviewed response or the [research brief workflow](/blog/ai-weekly-research-brief) for recurring background research.'))
 ]
},
{
 slug: 'ai-study-tutor-mac', category: 'Workflows', topic: 'Learning',
 title: 'Create a study tutor mate that helps you practice on Mac',
 description: 'Build a HeyMate tutor with retrieval practice, small exercises, and source checks. Includes a role prompt and a repeatable review routine.',
 answer: 'A HeyMate tutor can keep a teaching role and help you practice a topic over time. Give it instructions to ask questions, wait for your answer, and check source material rather than immediately producing a finished solution.',
 related: ['learn-mac-apps-with-ai', 'visual-explanations-on-mac', 'choose-open-source-ai-assistant-mac'],
 sections: [
 section('Tell the tutor how to teach',
 p('A helpful study session starts with your current understanding and a specific objective. Name the topic, your experience, and the material you are using. Ask the tutor to find gaps before choosing an explanation. HeyMate mates can hold a role, habits, notes, and a workspace, so the teaching instructions do not need to be reinvented for every session.'),
 prompt('Create a patient tutor for the subject I name. First ask what I already know. Teach one small idea at a time, ask me to explain it back, and wait for my answer. Give hints before full solutions. Flag uncertainty and ask for the source material when precision matters.')),
 section('Use an explain, try, recall loop',
 steps('Choose one concept and read a short passage from your course or reference.', 'Ask the tutor for a plain explanation and one worked example.', 'Attempt a similar problem yourself, without seeing the answer.', 'Explain your reasoning and ask where it breaks down.', 'Close the notes and recall the key idea in your own words.'),
 p('This is a suggested practice structure, not a measured claim that HeyMate improves learning outcomes. The useful test is whether you can solve a fresh problem and explain why your answer works. If the tutor keeps supplying the answer too soon, make the “wait for me” instruction explicit.')),
 section('Use screen guidance for software practice',
 p('When the subject is an app, bring a sample task into view and use a vision-capable provider. HeyMate can point to the current control and wait while you try the step. Ask for a second task that uses the same concept in a slightly different way. Read [learning Mac apps](/blog/learn-mac-apps-with-ai) for that workflow.'),
 prompt('I completed the example. Give me a new practice task that tests the same idea. Do not describe the steps unless I ask for a hint. Afterward, ask me why I chose those controls.')),
 section('Keep a useful learning record',
 list('What you can now explain without notes.', 'Which errors you made and why the correction matters.', 'One unresolved question tied to a source.', 'A small exercise to try next time.'),
 p('A routine can prompt another review, using the scheduling controls available in your app version. Do a short manual session first and check that the questions match your level. A schedule does not guarantee that the model remembers every detail or understands a course’s marking criteria; use your own learning record as the reference.')),
 section('Keep expert sources in the loop',
 p('Use the official course, textbook, or software documentation to verify definitions, formulas, and exam rules. A confident generated explanation may still be wrong. Do not use this workflow as a substitute for qualified medical, legal, or other professional instruction.'),
 p('Text questions do not require screen access. Screen guidance needs a vision-capable provider; HeyMate’s optional Apple Intelligence route is text-only. Review [provider setup](/connect-claude-codex) and [privacy](/privacy) before showing private coursework or documents.'))
 ]
},
{
 slug: 'visual-explanations-on-mac', category: 'Workflows', topic: 'Visual answers',
 title: 'Ask HeyMate for diagrams and visual explanations on your desktop',
 description: 'Explore real HeyMate recordings of a recipe sketch, Raspberry Pi connection diagram, and 3D board explanation, with prompts for clearer follow-ups.',
 answer: 'HeyMate can draw 2D explanations, connection diagrams, and 3D graphics over the desktop. Use a visual answer to understand a relationship or process, then verify details against an authoritative source when accuracy matters.',
 related: ['ai-study-tutor-mac', 'ai-design-review-figma', 'learn-mac-apps-with-ai'],
 sections: [
 section('Choose the relationship you want to see',
 p('A drawing is useful when a paragraph hides the structure of a problem. Ask for the layers in a recipe, the path between two parts, or a labeled view of an object. Start by naming the concept and the kind of explanation you need. A simple diagram can be more useful than a detailed picture if the goal is to understand what connects to what.'),
 prompt('Explain the relationship between these parts with a simple labeled diagram. Keep the first version minimal. Ask me what is unclear before adding detail. Distinguish the conceptual sketch from exact dimensions.')),
 section('See the actual examples',
 image('/assets/video/visual-answers/camera-960.webp', 'HeyMate drawing a Raspberry Pi camera connection explanation over a desktop.', 960, 522, 'Actual HeyMate example. Generated diagrams need independent verification.'),
 list('[Chicken biryani explanation](/assets/video/visual-answers/biryani.mp4): a 2D sketch of ingredients and layers.', '[Raspberry Pi camera diagram](/assets/video/visual-answers/camera.mp4): a drawn explanation of the board, connector, and cable.', '[3D board explanation](/assets/video/visual-answers/board.mp4): a view of the board’s shape, ports, and parts.'),
 p('The website recordings are actual HeyMate examples, condensed and sped up, with silent previews. They show the output for those questions; they are not a guarantee that every future question will produce the same quality or that the labels are technically authoritative.')),
 section('Ask follow-ups that improve the explanation',
 prompt('Which part should I look at first? Show the direction of the connection and explain it in one sentence. If you are uncertain about the hardware revision, ask me to identify it.'),
 p('For a recipe or process, ask what happens before and after the current step. For a diagram, ask which labels refer to physical parts and which describe an abstract relationship. For a 3D view, ask for a simpler angle instead of adding more decoration. The aim is comprehension, not a more impressive graphic.')),
 section('Verify before using a drawing as instructions',
 p('A generated hardware diagram is not a wiring specification. Check the manufacturer’s documentation for the exact model and revision, connector orientation, power requirements, and pin assignment. Do not connect components or power a circuit based only on an AI sketch. Similar care applies to any diagram whose error could damage equipment or affect safety.'),
 p('A visual explanation can help you understand official instructions, but it should not silently replace them. Tell HeyMate when you are using the drawing for a real task, and ask which details need independent checking. If it cannot identify a source, keep the picture conceptual.')),
 section('Try a small question on your Mac',
 p('Use sample material and a compatible provider, then ask one question with a clear learning goal. If you need the assistant to interpret the current screen, use a vision-capable provider and review [screen permissions](/permissions). The optional Apple Intelligence provider in HeyMate is text-only and cannot see your screen.'),
 p('Explore the [recorded visual answers](/#visual-answers), [provider connection guide](/connect-claude-codex), and [privacy details](/privacy). Questions and context go to the selected provider when required; open-source app code does not make every provider interaction local.'))
 ]
},
{
 slug: 'heymate-vs-raycast', category: 'Comparisons', topic: 'Raycast alternative',
 title: 'HeyMate vs Raycast: which Mac AI workflow fits you?',
 description: 'Compare HeyMate and Raycast for guided learning, AI subscriptions, agents, and daily workflows. Includes official sources and reasons to choose either.',
 answer: 'Consider HeyMate when you want an open-source desktop companion, spoken screen guidance, and specialist mates without a HeyMate subscription. Consider Raycast when its integrated AI, command interface, and extension ecosystem fit your existing workflow. Both support existing Claude or ChatGPT subscriptions.',
 related: ['heymate-vs-alfred', 'choose-open-source-ai-assistant-mac', 'ai-design-review-figma'],
 sections: [
 section('Where the products overlap',
 p('Raycast’s current [AI product page](https://www.raycast.com/core-features/ai) describes screen awareness, custom agents, projects, automations, and extensions. Its [subscription guide](https://manual.raycast.com/ai/bring-your-own-subscription) documents using Claude or ChatGPT through the provider’s CLI, with a paid Raycast plan. Usage goes against that provider subscription rather than Raycast AI credits.'),
 p('That overlap matters: bringing your own AI subscription is not unique to HeyMate. Choose based on the interaction you want, the tools you already use, and the total cost of your setup. This is a project-published comparison based on documentation checked November 1, 2026, not a hands-on speed or accuracy benchmark.')),
 section('Compare the decision points',
 table(['Question', 'HeyMate', 'Raycast'], [
 ['How do I interact?', 'Push-to-talk, spoken guidance, a desktop pointer, and specialist mates.', 'AI chat, commands, agents, and extension-driven workflows; see the AI overview linked above.'],
 ['Can I use an existing subscription?', 'Claude Code, Codex, and other configured routes; provider limits apply.', 'Claude or ChatGPT via CLI on a paid Raycast plan, per its subscription guide.'],
 ['What do I pay for the app?', 'MIT licensed; no HeyMate subscription. Optional services can charge.', 'Raycast AI is part of paid Pro plans; check current terms rather than assuming a fixed price.'],
 ['What should I verify?', 'Provider vision support, required permissions, and current self-signed installer caveats.', 'Plan access, current system requirements, supported models, and required extensions.']]),
 p('Raycast plan and feature statements above come from its [official AI overview](https://www.raycast.com/core-features/ai). HeyMate requirements and signing details are documented in the [project README](https://github.com/UmarSiddiqui/heymate).')),
 section('When HeyMate is worth trying',
 p('Try HeyMate if your question is often “what am I looking at, and what should I try next?” Its guided-learning pattern lets you perform the task while the assistant explains the current step. A named mate can also keep a recurring role and habits, while optional notch tools keep small utilities nearby.'),
 p('HeyMate supports macOS 14.2 or later on Apple silicon and Intel; screen guidance still needs a vision-capable provider. Current builds are self-signed rather than Apple Developer ID signed or notarized. Those installation tradeoffs belong in the decision alongside the absence of a HeyMate subscription.')),
 section('When Raycast may be the better choice',
 p('Choose Raycast if the workflow described in its documentation already matches how you work and the paid plan fits your budget. There is little reason to switch a working tool solely to obtain a feature both products offer. A launcher-centered routine and a companion-centered routine may also coexist rather than compete for every task.'),
 p('Avoid judging either tool from a model name alone. Give each the same sample task, verify the output, and record how much setup and correction you needed. That produces evidence about your use case instead of an unsupported claim that one product is universally better.')),
 section('A practical comparison you can run',
 steps('Use a non-sensitive sample task in an app you already know.', 'Ask for an explanation, one next step, and a way to verify the result.', 'Repeat with the same provider where feasible, noting any differences in tool access.', 'Compare the result, interaction, account permissions, and total ongoing cost.'),
 p('For HeyMate, start with [provider setup](/connect-claude-codex) and [screen guidance](/screen-guidance). This article is not affiliated with or endorsed by Raycast. Vendor features and plans can change.'))
 ]
},
{
 slug: 'heymate-vs-alfred', category: 'Comparisons', topic: 'Alfred alternative',
 title: 'HeyMate vs Alfred: AI guidance or repeatable Mac workflows?',
 description: 'Compare HeyMate with Alfred for app learning, repeatable workflows, text snippets, and file tasks. Learn when they complement each other.',
 answer: 'Choose HeyMate for conversational explanations, screen guidance, and model-driven tasks. Choose Alfred when you want an explicit workflow or reusable text snippet. They can complement one another: an AI conversation can help plan work that a fixed workflow later repeats.',
 related: ['heymate-vs-apple-shortcuts', 'organize-files-with-ai-on-mac', 'draft-email-with-ai-on-mac'],
 sections: [
 section('Start with the kind of repetition',
 p('Some tasks repeat exactly; others require interpretation each time. That is a more useful starting point than asking which app has the longest feature list. If the same input should always produce the same known transformation, an explicit workflow is often easier to inspect. If the task is an unfamiliar interface or a messy request, conversation can help define what should happen.'),
 p('Alfred’s [workflow documentation](https://www.alfredapp.com/help/workflows/) describes connecting triggers, inputs, actions, and outputs, with workflows available through Powerpack. Its [snippet documentation](https://www.alfredapp.com/help/features/snippets/) describes reusable text and automatic expansion, also a Powerpack feature. This comparison uses those official descriptions, checked November 1, 2026; it is not a performance benchmark.')),
 section('Compare representative tasks',
 table(['Task', 'A useful starting point', 'Reason'], [
 ['Explain a confusing app screen', 'HeyMate with a vision-capable provider', 'The task needs contextual explanation and a pointer.'],
 ['Paste the same approved paragraph repeatedly', 'Alfred snippets', 'The wording is fixed; regeneration is unnecessary.'],
 ['Run a known chain of actions from a trigger', 'An Alfred workflow', 'The steps and output can be defined explicitly.'],
 ['Plan a new organization rule for a sample folder', 'HeyMate for discussion and a reviewed plan', 'The rule itself is still being worked out.']]),
 p('The Alfred examples refer to its documented [snippets](https://www.alfredapp.com/help/features/snippets/) and [workflow model](https://www.alfredapp.com/help/workflows/). They do not claim that Alfred extensions cannot add AI or that HeyMate replaces every launcher feature.')),
 section('Where HeyMate fits',
 p('HeyMate offers push-to-talk questions, spoken answers, screen guidance, and specialist mates. You can ask for one step at a time while you learn an app, or review a plan before an approved coding job. Its AI routes include Claude Code, Codex, OpenCode, and a custom Anthropic-compatible API; capabilities vary by route.'),
 p('The app is MIT licensed and adds no subscription fee, but AI providers and optional services can charge separately. It runs on macOS 14.2 or later on Apple silicon and Intel. Current builds use a stable self-signed certificate and are not Apple notarized. Read the [setup guide](/connect-claude-codex) before deciding whether that fits your machine.')),
 section('Where a fixed workflow wins',
 p('For a routine with known steps, you may prefer to review the logic once and run it repeatedly. A generated explanation is not automatically an improvement over a reliable workflow. Keep standard addresses, boilerplate, and approved wording in a reusable form when exact text matters. Use AI when interpretation adds value, not simply because it is available.'),
 p('A hybrid approach is practical: discuss the desired workflow with HeyMate, build it in the tool you prefer, and test the fixed routine with sample inputs. Do not claim a workflow is reliable until you have checked its normal case, missing input, and failure behavior.')),
 section('Try before replacing your setup',
 prompt('Help me decide whether this task needs AI interpretation or a fixed workflow. Describe the input, the output, and every decision point. If there are no variable decisions, suggest a repeatable approach instead of an agent.'),
 p('Compare the effort to set up, inspect, and correct the task. Review tool permissions and data handling, especially for private files or clipboard contents. See [file organization](/blog/organize-files-with-ai-on-mac) and [email drafting](/blog/draft-email-with-ai-on-mac) for examples.'),
 p('Published by the HeyMate project, with no affiliation or endorsement from Alfred. Consult Alfred’s current documentation for features and Powerpack terms.'))
 ]
},
{
 slug: 'heymate-vs-claude-cowork', category: 'Comparisons', topic: 'Claude Cowork alternative',
 title: 'HeyMate vs Claude Cowork: choose your desktop AI workflow',
 description: 'Compare HeyMate and Claude Cowork for guided learning, delegated tasks, provider choice, and data handling, using current official documentation.',
 answer: 'Consider HeyMate for open-source Mac companionship, provider choice, and guidance while you work. Consider Claude Cowork for its integrated Claude task environment and deliverable-focused workflows. Both can support delegated work, so guidance versus automation is a preference rather than an exclusive capability.',
 related: ['ai-weekly-research-brief', 'ai-meeting-prep-mac', 'explain-terminal-errors-with-ai'],
 sections: [
 section('Account for what Cowork can do now',
 p('Anthropic’s current [Cowork getting-started guide](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork) describes tasks running in an isolated cloud environment, with local access through the desktop app when needed. It requires a paid Claude plan and an active internet connection. Its [product page](https://claude.com/product/cowork) describes work across files and tools, recurring tasks, and outputs for review.'),
 p('Anthropic also documents [computer use](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork): Claude can interact with apps through screen actions when appropriate tools are unavailable. Do not compare today’s HeyMate with an outdated picture of Cowork as only a text chat window. Sources checked November 1, 2026; this is not a hands-on benchmark.')),
 section('Compare the choices that affect your work',
 table(['Decision', 'HeyMate', 'Claude Cowork'], [
 ['Provider relationship', 'Choose configured Claude, Codex, OpenCode, or compatible API routes.', 'Work in Anthropic’s Claude environment.'],
 ['Typical interaction', 'Push-to-talk, pointers, screen walkthroughs, specialist mates, and approved jobs.', 'Describe an outcome, review progress, and receive work in the Cowork session.'],
 ['Background work', 'Enabled routines and approved jobs can continue in the background.', 'Cloud sessions can continue with the laptop closed; local access needs the connected desktop app.'],
 ['Cost framing', 'No HeyMate subscription; provider and optional service fees remain.', 'Paid Claude plan and its usage rules.']]),
 p('Cowork execution and account details above come from its [official getting-started guide](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork). Product access and rollout details can change.')),
 section('Why you might choose HeyMate',
 p('HeyMate is a fit when you want to learn a visible Mac task while doing the work yourself, or prefer an open-source companion whose code you can inspect. You can keep named mates with roles and habits, and choose among supported provider routes instead of committing every task to one vendor environment.'),
 p('That does not make every interaction local or every provider equally capable. Screen guidance needs vision support. HeyMate chat history is local, but relevant questions and screen images can go to the selected provider. Some integrations write temporary screenshots. Current installers are self-signed and not Apple notarized; that tradeoff should be explicit.')),
 section('Why you might choose Cowork',
 p('Cowork is worth considering when its documented task environment, connected tools, and deliverable workflow match your goal. If you already work comfortably in Claude, evaluate that experience before adding another app. Check whether the task needs a local computer connection or can finish entirely in the cloud, using the requirements Anthropic documents.'),
 p('Neither product should be treated as infallible. Give the same sample assignment, specify the output and permissions, and verify the result. A useful comparison records missing context, corrections, and review effort rather than awarding a winner because one answer sounds more polished.')),
 section('Run a fair sample task',
 prompt('Using only these sample documents, produce a short brief with source references and unresolved questions. Show your plan first. Do not send messages, change remote accounts, or invent missing facts. Tell me which inputs you could not access.'),
 p('For HeyMate, follow [provider setup](/connect-claude-codex) and review [privacy](/privacy). Then try [a research brief](/blog/ai-weekly-research-brief) or [meeting preparation](/blog/ai-meeting-prep-mac). This comparison is published by HeyMate and is not endorsed by Anthropic.'))
 ]
},
{
 slug: 'heymate-vs-apple-shortcuts', category: 'Comparisons', topic: 'Mac automation',
 title: 'HeyMate vs Apple Shortcuts: conversation or a defined automation?',
 description: 'Compare HeyMate and Apple Shortcuts for learning tasks, repeatable actions, and AI-assisted workflows. Includes a practical way to use both together.',
 answer: 'Use HeyMate when you need to explain a goal, interpret context, or learn an interface. Use Apple Shortcuts when you want to compose and run a defined sequence of available actions. A conversation can help you design a shortcut without replacing its explicit logic.',
 related: ['heymate-vs-alfred', 'organize-files-with-ai-on-mac', 'learn-mac-apps-with-ai'],
 sections: [
 section('What each approach starts with',
 p('Apple’s [Shortcuts guide for Mac](https://support.apple.com/en-au/guide/shortcuts-mac/welcome/mac) describes shortcuts as one or more actions that work with apps and content. You compose those actions into a sequence. Apple’s [introduction](https://support.apple.com/en-ca/guide/shortcuts-mac/apdf22b0444c/mac) also describes running shortcuts with a click or through Siri.'),
 p('HeyMate starts with a question or task description. A selected AI provider interprets the request, and a screen walkthrough can point to the next control while you do the work. For delegated jobs, review the plan and approve execution. The difference is the work you need from the tool, not a claim that one product is always more capable.')),
 section('Compare tasks, not labels',
 table(['Situation', 'Useful starting point', 'What to check'], [
 ['You know the actions and their order', 'Apple Shortcuts', 'Whether the required actions and input types are available.'],
 ['You do not understand the app screen yet', 'HeyMate screen guidance', 'Provider vision support and macOS permissions.'],
 ['The same routine needs different input each time', 'A shortcut with explicit inputs', 'Validation and what happens when an input is missing.'],
 ['The task requires interpreting uncertain information', 'A scoped AI conversation or agent task', 'Sources, approval boundaries, and how you will verify the answer.']]),
 p('The shortcut examples follow Apple’s documented action-based model. They are workflow suggestions, not a tested compatibility list or a claim that Shortcuts cannot include AI services. Available actions depend on the apps and system version you use.')),
 section('Use HeyMate to plan before automating',
 prompt('Help me describe this repeated task as inputs, actions, decisions, and outputs. Ask what is missing. If a step can be expressed as a fixed rule, keep it explicit rather than replacing it with a model judgment.'),
 p('Walk through the process manually once. Note where you actually make a decision and where you follow a known rule. Then build the defined portion in Shortcuts if the needed actions exist. Use sample inputs to test the normal path, an empty input, and an unavailable destination before relying on the automation.'),
 p('If you need help understanding the Shortcuts interface itself, HeyMate can discuss the visible screen through a vision-capable provider. That is screen guidance, not proof that a proposed shortcut has valid actions or will run correctly. Check the actual blocks and test the result.')),
 section('Keep permissions and side effects explicit',
 p('A fixed sequence can still send something to the wrong place if its input is wrong. A model-driven task can still misinterpret a goal. Review the destination and effect of messages, deletions, purchases, and remote changes regardless of which tool starts them. Do not assume that all actions can be undone.'),
 p('HeyMate supports configurable integrations, including Apple apps and local tools. Access depends on what you enable. Relevant questions and screen context can go to your selected provider, and enabled routines or approved jobs can run in the background. Read the [permissions guide](/permissions) and [privacy details](/privacy).')),
 section('Choose the smallest workflow that does the job',
 p('For a stable routine, the simplest explicit automation may be enough. For learning and questions about changing context, try the conversational route. You can keep both: use a mate to clarify an unfamiliar task, then use a defined shortcut once the process is understood.'),
 p('This comparison is published by the HeyMate project using Apple documentation checked November 1, 2026. It is not affiliated with Apple. For related examples, read [file organization](/blog/organize-files-with-ai-on-mac) and [learning a Mac app](/blog/learn-mac-apps-with-ai).'))
 ]
},
{
 slug: 'choose-open-source-ai-assistant-mac', category: 'Choosing tools', topic: 'Buying guide',
 title: 'How to choose an open-source AI assistant for Mac',
 description: 'Evaluate Mac AI assistants by workflow, provider access, privacy, permissions, installation, and total cost. Includes a practical HeyMate evaluation checklist.',
 answer: 'Choose by the task you want to complete and the access you are comfortable granting. Open-source app code helps inspection, but it does not guarantee local processing, correct answers, private providers, or a notarized installer.',
 related: ['heymate-vs-raycast', 'heymate-vs-claude-cowork', 'learn-mac-apps-with-ai'],
 sections: [
 section('Start with the interaction you need',
 p('A Mac AI assistant can mean a chat window, a command launcher, a screen tutor, or an agent that changes files. Write down one task you actually repeat and the result you want. If you mainly need the same fixed text inserted, a snippet may be enough. If you want to understand unfamiliar software, prioritize the explanation and review loop.'),
 list('Guidance: you do the task while the assistant explains and points.', 'Delegation: the agent plans and performs scoped work for review.', 'Repetition: a defined workflow applies known steps to a new input.', 'Research: tools gather current sources and separate evidence from interpretation.'),
 p('These categories overlap. The important question is how much interpretation the task needs and how easily you can inspect the result. A longer feature list does not establish a better fit for your routine.')),
 section('Separate app licensing from provider cost',
 p('HeyMate is MIT licensed and adds no subscription fee. It can use configured Claude Code, Codex, OpenCode, and custom Anthropic-compatible API routes. Those providers have their own limits, account requirements, and charges; optional voice and connector services can also cost money.'),
 p('When comparing products, ask what you pay for the app, what you pay for inference, and what connected services charge. Reusing an existing subscription can be useful, but it is not unique to HeyMate: [Raycast also documents that route](/blog/heymate-vs-raycast). Look at current terms rather than a comparison’s old price screenshot.')),
 section('Check what “local” actually covers',
 p('Ask separately about chat storage, model inference, speech processing, credentials, temporary files, and connected services. Local chat history does not mean the model ran locally. Open-source app code does not determine a cloud provider’s retention policy.'),
 p('In HeyMate, local history stores text, while relevant questions and screen images can go to the selected provider. Some integrations write temporary screenshots; interrupted cleanup can leave files behind. Optional Apple Intelligence is text-only on eligible Macs running macOS 26 or later and cannot see the screen. Review the detailed [privacy explanation](/privacy).')),
 section('Review installation and access',
 p('HeyMate supports macOS 14.2 or later on Apple silicon and Intel. Current builds use a stable self-signed certificate and are not Apple Developer ID signed or notarized. That differs from a polished installation experience you may expect from another vendor. Read the [setup guide](/connect-claude-codex) and decide whether the tradeoff is acceptable.'),
 p('For any assistant, review the permissions the chosen task needs. A question about text need not become broad access to your entire desktop. Screen guidance needs a vision-capable provider and appropriate permissions. Connected tools have their own account scope, and local undo cannot reverse every external action.')),
 section('Run one evaluation with sample content',
 steps('Choose a small task with an answer or outcome you can verify.', 'Use non-sensitive sample content and grant only relevant access.', 'Record setup effort, corrections, and what data leaves the machine.', 'Check the output against the original evidence.', 'Decide whether the result is useful enough to keep using the tool.'),
 p('HeyMate is worth evaluating if a desktop companion, spoken guidance, and specialist mates match the way you work. Another tool may fit better if its explicit workflows, integrated environment, or installation model matter more. See the comparisons with [Alfred](/blog/heymate-vs-alfred), [Apple Shortcuts](/blog/heymate-vs-apple-shortcuts), and [Claude Cowork](/blog/heymate-vs-claude-cowork). No universal ranking or reliability percentage is established by these guides.'))
 ]
}
];
