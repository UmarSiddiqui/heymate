//
//  DefaultSkillCatalog.swift
//  leanring-buddy
//
//  Clean-room default skill files bundled with the app (master spec FR-13).
//  HeyClicky ships a curated skill library; HeyMate ships its own original
//  set tuned to this app's actual capabilities: screen-aware conversation,
//  voice dictation, on-screen annotations, and memory. Entries are seeded
//  into the user's skills folder by SkillMarkdownParser.seedDefaultsIfNeeded
//  so they can be edited or deleted like any user skill.
//

import Foundation

nonisolated enum DefaultSkillCatalog {

    /// Bundled defaults. `fileName` becomes the on-disk name in the skills
    /// directory; `markdown` must parse via SkillMarkdownParser.parse.
    nonisolated static let skills: [(fileName: String, markdown: String)] = [
        screenWalkthrough,
        dictateAndRefine,
        meetingBraindump,
        codeExplainer,
        studyTutor,
        inboxTriage,
        researchBrief,
        uiDesignCritique,
        difficultConversation,
    ]

    // MARK: - Definitions

    private static let screenWalkthrough = (
        fileName: "screen-walkthrough.md",
        markdown: """
        ---
        name: screen-walkthrough
        trigger: walk me through what is on my screen, where is it, show me which button or setting
        tools:
        ---

        # Guided walkthrough of visible UI

        When asked to find something or walk through the current screen:

        1. Look at the screenshot and identify the exact element being asked about.
        2. Describe the path from an obvious landmark ("top-right corner", "under the sidebar").
        3. Emit a visualActions block that circles the target element so the answer is visual,
           not just verbal. One annotation per step; keep labels under four words.
        4. If the element is not visible, say so plainly and ask for the missing screen
           instead of guessing coordinates.

        Keep spoken steps short — one sentence per step, then point.
        """
    )

    private static let dictateAndRefine = (
        fileName: "dictate-and-refine.md",
        markdown: """
        ---
        name: dictate-and-refine
        trigger: write this for me, polish my words, make this professional, rewrite what I said, fix my dictation
        tools:
        ---

        # Dictation cleanup and rewriting

        Spoken input arrives with filler words, false starts, and no punctuation.

        When the user dictates content meant for another app (email, chat, document):

        1. Output ONLY the cleaned text, ready to paste — no preamble, no commentary.
        2. Fix punctuation, capitalization, and obvious speech-to-text mishearings using
           surrounding context.
        3. Preserve the speaker's meaning, tone, and level of formality. Do not embellish.
        4. When asked to "make it professional" or similar, tighten wording but keep length
           within roughly 20% of the original unless told otherwise.
        """
    )

    private static let meetingBraindump = (
        fileName: "meeting-braindump.md",
        markdown: """
        ---
        name: meeting-braindump
        trigger: notes from this call, summarize the meeting, action items, what did I just discuss
        tools:
        ---

        # Meeting notes from a spoken braindump

        The user just talked through a meeting, call, or working session out loud.

        Produce three short sections, exactly these headers:

        ## Decisions
        ## Action items
        ## Open questions

        Rules:
        - Action items get an owner whenever one was mentioned; write "unassigned" otherwise.
        - Never invent decisions that were only floated as possibilities.
        - If the braindump contains numbers, dates, or names, reproduce them exactly.
        - Keep the whole output under 150 words unless explicitly asked for detail.
        """
    )

    private static let codeExplainer = (
        fileName: "code-explainer.md",
        markdown: """
        ---
        name: code-explainer
        trigger: explain this code, why does this crash, review my code, what does this function do
        tools:
        ---

        # Explaining and reviewing code on screen

        The visible window usually contains the relevant file. Use it as ground truth.

        1. Answer the specific question first. Do not restate the whole file.
        2. Reference symbols by name and location ("the retry closure in fetchTickets").
        3. For bug hunts, list at most three candidate causes ranked by likelihood, each
           with the one-line evidence that supports it.
        4. Circle the suspicious line with a visualActions roundedRect when the cause is
           visible in the screenshot.
        5. If the visible snippet is insufficient to answer confidently, say what extra
           context you need instead of speculating.
        """
    )

    private static let studyTutor = (
        fileName: "study-tutor.md",
        markdown: """
        ---
        name: study-tutor
        trigger: help me understand this concept, quiz me, explain this diagram, teach me this topic
        tools:
        ---

        # Tutoring from screen content

        The user is studying material visible on their screen (slides, docs, papers).

        1. Diagnose first: ask one clarifying question if the request is broader than one
           concept; otherwise proceed directly.
        2. Explain in layers: plain-language intuition first, precise terminology second.
        3. Anchor explanations to what is visible — refer to "the left graph", "equation 2".
        4. End with one check-for-understanding question the user can answer verbally.
        5. When quizzed, wait for the user's answer before revealing yours; never grade
           harshly — correct misconceptions by building on what was right.
        """
    )

    private static let inboxTriage = (
        fileName: "inbox-triage.md",
        markdown: """
        ---
        name: inbox-triage
        trigger: triage my inbox, which email should I answer, draft a reply to this message
        tools:
        ---

        # Inbox and message triage

        Applies when the visible screen shows mail or chat threads and the user asks what
        matters or how to reply.

        1. Triage verdicts are one line each: sender, why it matters (or not), suggested
           action (reply / read later / archive).
        2. Reply drafts follow dictate-and-refine conventions: paste-ready text only.
        3. Never produce send-ready output without showing the recipient, subject, and body
           summary first, and never claim a message was sent — HeyMate has no send access.
        4. Sensitive content (money, legal, HR, personal news) gets an explicit "review
           carefully" flag regardless of apparent urgency.
        """
    )

    private static let researchBrief = (
        fileName: "research-brief.md",
        markdown: """
        ---
        name: research-brief
        trigger: research this topic for me, give me a briefing, catch me up on, compare these options, pros and cons of
        tools:
        ---

        # Spoken research briefings

        The user wants to get smart on a topic or decide between options.

        1. Open with the one-sentence answer or recommendation, then supporting layers.
        2. For comparisons: at most three dimensions that actually differentiate the
           options; skip dimensions where everything ties.
        3. Separate what you know from what you're inferring — say "I'm not certain" once,
           plainly, rather than hedging every sentence.
        4. Written output (when asked) uses short sections with bold headers; spoken output
           follows write-for-the-ear rules from the main prompt.
        5. If the visible document relates to the question, ground claims in it first and
           say which parts came from it.
        """
    )

    private static let uiDesignCritique = (
        fileName: "ui-design-critique.md",
        markdown: """
        ---
        name: ui-design-critique
        trigger: review my design, does this look good, feedback on this screen, critique this ui, is this layout right
        tools:
        ---

        # Design critique from screenshots

        The visible screen shows UI under construction (or a design file). Give feedback
        like a senior product designer would in a quick pass.

        1. Lead with what works — one specific thing, not generic praise.
        2. Then at most three concrete issues, ordered by impact: hierarchy, spacing and
           alignment, contrast and readability, consistency of components.
        3. Every issue names the exact element on screen plus one actionable fix
           ("increase the gap between the two cards to about 16 points").
        4. Draw attention to the worst offender with a visualActions highlight so the
           critique is anchored visually.
        5. No redesign fantasies — critique what exists at the fidelity shown.
        """
    )

    private static let difficultConversation = (
        fileName: "difficult-conversation.md",
        markdown: """
        ---
        name: difficult-conversation
        trigger: help me say no, how do I tell them, negotiate salary, awkward conversation with my boss, respond to this complaint
        tools:
        ---

        # Difficult conversations and negotiation

        The user needs to say something delicate — to a boss, client, partner, or vendor.

        1. Get the goal straight first: what outcome would make this conversation a win?
           One clarifying question if unclear, otherwise infer it and state the assumption.
        2. Draft the actual words they could say or send — direct, warm, no corporate
           filler. Lead with the substance, not throat-clearing.
        3. Offer exactly one firmer variant and one softer variant when tone is genuinely
           uncertain; otherwise commit to one version.
        4. Flag real stakes honestly (legal exposure, burned bridges) without moralizing.
        5. Never roleplay sending anything — output is for the user to deliver themselves.
        """
    )
}
