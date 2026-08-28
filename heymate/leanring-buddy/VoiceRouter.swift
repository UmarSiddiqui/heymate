//
//  VoiceRouter.swift
//  leanring-buddy
//
//  Isolated regex predicates plus a tiny RouteDecision. This is the free tier
//  of a two-tier router: it answers what it can answer without a round trip
//  and hands everything genuinely ambiguous to `VoiceIntentClassifier`.
//
//  The point of that split is that this file must NOT grow. Every new guard
//  here is a rule someone has to keep true forever; the classifier is one call
//  that generalises. If a case is being missed, the fix is almost always the
//  classifier's prompt, not another regex. Do not grow this into OpenClicky's
//  13-guard cascade.
//

import Foundation

nonisolated enum VoiceRouteDecision: Equatable {
    case local(LocalVoiceAction)
    case agent
    case hybrid
    case confirmDestructive
    case talk
    /// Nothing free could decide this one. `VoiceIntentClassifier` gets a
    /// turn, and its failure falls back to `fallbackDecision`.
    case needsClassification
}

nonisolated enum VoiceRouter {

    /// Everything that can be decided for free, decided for free.
    ///
    /// Order matters and each step earns its place: a local shortcut must not
    /// pay a round trip, an explicit "agent," is the user having already
    /// decided, and a question about what is on screen is the single most
    /// common thing said to this app — sending that to a classifier would add
    /// half a second to almost every turn to be told what it plainly is.
    ///
    /// Everything left over is genuinely ambiguous and goes to the model.
    /// This is deliberately five steps, not thirteen.
    static func decide(_ transcript: String) -> VoiceRouteDecision {
        if let local = LocalVoiceAction.parse(transcript) {
            return .local(local)
        }

        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)

        let explicitAgentTask = AgentInvocation.explicitPrefixTask(transcript)

        if isSensitiveOrDestructiveAgentTaskRequest(normalized), explicitAgentTask == nil {
            return .confirmDestructive
        }
        if explicitAgentTask != nil {
            return .agent
        }
        // Hybrid is checked before the screen question, because "what is this
        // error and also fix it in the background" satisfies both and the
        // background half is the part that would be lost.
        if containsHybridForegroundCue(normalized), containsHybridBackgroundCue(normalized) {
            return .hybrid
        }
        if isScreenQuestion(normalized) {
            return .talk
        }
        // "open this", "read that out" — pointing at what is visible with
        // nothing durable named. There is no folder in it, so there is nothing
        // for an agent to do and nothing worth a round trip.
        if containsReferentialWorkTarget(normalized), !containsDurableWorkTarget(normalized) {
            return .talk
        }
        return .needsClassification
    }

    /// Used when the classifier is unreachable. This is the old behaviour —
    /// prefixes plus a fixed list of coding nouns — kept as a floor so a
    /// network failure degrades to what shipped before rather than to nothing.
    static func fallbackDecision(_ transcript: String) -> VoiceRouteDecision {
        AgentInvocation.isAgentRequest(transcript) ? .agent : .talk
    }

    /// A question about what the person is looking at. Never agent work, so
    /// it can skip the classifier: an interrogative opener plus a reference to
    /// something visible. "What does this error mean" qualifies; "clean up my
    /// Downloads folder" does not.
    static func isScreenQuestion(_ normalized: String) -> Bool {
        let openerPattern = #"^(?:what|why|how|who|when|where|which|explain|describe|tell\s+me|whats|whos)\b"#
        guard normalized.range(of: openerPattern, options: .regularExpression) != nil else {
            return false
        }
        let screenReferencePattern = #"\b(?:this|that|it|here|screen|display|visible|selected|highlighted|window|page|says|saying|shown|showing)\b"#
        return normalized.range(of: screenReferencePattern, options: .regularExpression) != nil
    }

    static func looksLikeAgentWork(_ normalized: String) -> Bool {
        containsAgentWorkAction(normalized) && containsDurableWorkTarget(normalized)
    }

    static func containsAgentWorkAction(_ normalized: String) -> Bool {
        let actionPattern = #"\b(?:check|look\s+at|take\s+a\s+look|inspect|review|audit|fix|modify|change|update|edit|build|create|make|write|draft|research|search|find|summari[sz]e|organize|clean\s+up|cleanup|test|run|install|compare|read|move|rename|delete|prune|optimi[sz]e|wire|implement|add|remove|route|delegate|ensure|verify|validate|confirm|diagnose|investigate|repair|polish|improve|finish|sort\s+out|deal\s+with|take\s+care\s+of|make\s+sure|look\s+into|figure\s+out)\b"#
        return normalized.range(of: actionPattern, options: .regularExpression) != nil
    }

    static func containsDurableWorkTarget(_ normalized: String) -> Bool {
        let targetPattern = #"\b(?:heymate|github|repo|repository|codebase|project|app|settings|preference|preferences|log|logs|memory|skill|skills|desktop|download|downloads|document|documents|folder|folders|file|files|code|diff|git|branch|pull\s+request|pr|issue|issues|bug|test|tests|build|swift|xcode|email|gmail|calendar|spreadsheet|sheet|doc|slides|voice|computer\s+use|tool|tools|tooling|model|models)\b"#
        return normalized.range(of: targetPattern, options: .regularExpression) != nil
    }

    static func containsFreshResearchRequest(_ normalized: String) -> Bool {
        let researchPattern = #"\b(?:latest|live|price|news|weather|schedule|standings|research|look\s+up|search\s+(?:the\s+)?web|google|browse)\b"#
        return normalized.range(of: researchPattern, options: .regularExpression) != nil
    }

    static func isSensitiveOrDestructiveAgentTaskRequest(_ normalized: String) -> Bool {
        let destructivePattern = #"\b(?:delete|remove|erase|wipe|destroy|drop|revoke|reset|nuke|clear|purge|uninstall|terminate|kill)\b"#
        let broadScopePattern = #"\b(?:all|everything|entire|whole)\b"#
        let destructiveTargetPattern = #"\b(?:file|files|folder|folders|directory|directories|repo|repository|branch|branches|commit|commits|tag|tags|history|database|databases|keychain|account|accounts)\b"#
        let sensitiveTargetsPattern = #"\b(?:account|accounts|credential|credentials|password|passwords|token|tokens|api\s*key|secret|secrets|permission|permissions|auth|ssh|private\s+key|keychain|database|databases|prod|production|system\s+settings)\b"#

        let hasDestructiveVerb = normalized.range(of: destructivePattern, options: .regularExpression) != nil
        let hasBroadScope = normalized.range(of: broadScopePattern, options: .regularExpression) != nil
        let hasDestructiveTarget = normalized.range(of: destructiveTargetPattern, options: .regularExpression) != nil
        let hasSensitiveTarget = normalized.range(of: sensitiveTargetsPattern, options: .regularExpression) != nil

        return hasSensitiveTarget || (hasDestructiveVerb && (hasBroadScope || hasDestructiveTarget))
    }

    static func containsHybridForegroundCue(_ normalized: String) -> Bool {
        let foregroundPattern = #"\b(?:what|why|how|who|when|where|explain|tell\s+me|describe|summari[sz]e|answer|quick\s+(?:answer|thought|view)|what\s+do\s+you\s+think|do\s+you\s+think)\b"#
        return normalized.range(of: foregroundPattern, options: .regularExpression) != nil
    }

    static func containsHybridBackgroundCue(_ normalized: String) -> Bool {
        let backgroundPattern = #"\b(?:background|agent|agents|agent\s+mode|do\s+the\s+work|work\s+on\s+it|take\s+care\s+of\s+it|also\s+(?:fix|implement|patch|research|find|check|review|update|change|build|create)|while\s+you(?:re)?\s+(?:at\s+it|doing\s+that)|combination\s+of\s+the\s+two)\b"#
        return normalized.range(of: backgroundPattern, options: .regularExpression) != nil
    }

    static func containsNaturalBackgroundWorkCue(_ normalized: String) -> Bool {
        let cuePattern = #"\b(?:make\s+sure|ensure|verify|validate|confirm|look\s+into|figure\s+out|sort\s+out|deal\s+with|take\s+care\s+of|get\s+(?:this|that|it|.+?)\s+working|wire\s+(?:up|in)|hook\s+(?:up|in)|set\s+up|finish|polish|improve|repair|diagnose|investigate)\b"#
        if normalized.range(of: cuePattern, options: .regularExpression) != nil {
            return true
        }
        let makeUsePattern = #"\b(?:make|have)\b.{1,80}\b(?:use|using|route|routing|send|sending|call|calling)\b"#
        return normalized.range(of: makeUsePattern, options: .regularExpression) != nil
    }

    static func containsReferentialWorkTarget(_ normalized: String) -> Bool {
        let referencePattern = #"\b(?:this|that|it|here|current\s+(?:file|screen|window|page|repo|repository|project|app)|visible\s+(?:file|code|screen|window|page)|selected\s+(?:text|file|code|region)|the\s+(?:current|visible|selected)\s+(?:thing|part|file|code|screen|window|page)|what\s+we\s+(?:just\s+)?(?:talked|discussed)\s+about|the\s+thing\s+from\s+before)\b"#
        return normalized.range(of: referencePattern, options: .regularExpression) != nil
    }
}
