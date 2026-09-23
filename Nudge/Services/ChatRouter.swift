//
//  ChatRouter.swift
//  Nudge
//
//  The Home chat's deterministic front door (cycle 2026-09-23, small-talk
//  polarity). Roman's rule: the cheap lane needs POSITIVE evidence of
//  chitchat; a work-signal list may only ever route toward capture, never
//  away from it. So the gate is a closed set of chitchat tokens and the
//  lane fires only when the whole message is made of them. Everything
//  else, including anything with a digit, goes to capture. No API call on
//  the cheap side: replies are templates.
//
//  Read by the Home chat, the eval harness, and the capture-history
//  exporter, so the rule exists once.
//

import Foundation

enum ChatRouter {

    // MARK: - The closed set

    enum SmallTalkKind: CaseIterable {
        case greeting, thanks, acknowledgement, laughter, farewell
    }

    /// Chitchat vocabulary by the reply it earns. `neutral` holds the
    /// function words that make whole phrases in-set ("thank you so much",
    /// "how do you do"); none of them is a task by itself and none decides
    /// the reply kind.
    static let content: [SmallTalkKind: Set<String>] = [
        .greeting: ["hi", "hello", "hey", "heya", "yo", "hiya", "morning", "evening",
                    "afternoon", "howdy", "sup", "how", "whats"],
        .thanks: ["thanks", "thank", "thx", "ty", "cheers", "appreciate", "appreciated"],
        .acknowledgement: ["ok", "okay", "k", "kk", "cool", "nice", "great", "awesome",
                           "perfect", "sweet", "got", "yes", "yep", "yeah", "yup", "no",
                           "nope", "nah", "sure", "alright", "fine", "sounds", "right",
                           "understood", "noted", "will", "gotcha", "roger"],
        .laughter: ["lol", "lmao", "haha", "hahaha", "ha", "heh", "hehe", "rofl"],
        .farewell: ["bye", "goodbye", "later", "cya", "night", "goodnight", "see"]
    ]
    static let neutral: Set<String> = ["good", "up", "are", "you", "do", "going", "its", "it", "s",
                                       "much", "so", "a", "lot", "lots", "that", "this", "for",
                                       "please", "and", "ya", "soon", "there", "then"]

    private static let allTokens: Set<String> = content.values.reduce(into: neutral) { $0.formUnion($1) }

    /// Reply precedence when a message mixes kinds ("ok thanks" → thanks).
    private static let precedence: [SmallTalkKind] = [.thanks, .laughter, .farewell, .greeting, .acknowledgement]

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// TRUE only when every token is chitchat and there is no digit. An
    /// empty token list (emoji, punctuation) is NOT chitchat: with no
    /// evidence either way, capture is the side that never loses work.
    static func isSmallTalk(_ text: String) -> Bool {
        guard text.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let words = tokenize(text)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { allTokens.contains($0) }
    }

    /// Which reply a chitchat message earns: the first kind in precedence
    /// order with a content token in the message. Only neutral words
    /// ("you there") → acknowledgement.
    static func smallTalkKind(_ text: String) -> SmallTalkKind {
        let words = Set(tokenize(text))
        for kind in precedence where !words.isDisjoint(with: content[kind] ?? []) {
            return kind
        }
        return .acknowledgement
    }

    // MARK: - Templates (no API call)

    static func smallTalkReply(for text: String) -> String {
        switch smallTalkKind(text) {
        case .greeting: return "Hey. Tell me what's on your mind and I'll sort it into your list."
        case .thanks: return "Anytime. Send the next thing whenever it comes up."
        case .acknowledgement: return "Got it."
        case .laughter: return "Ha. I'm here when the next thing comes up."
        case .farewell: return "See you. I'll be here when you're back."
        }
    }

    /// The one line for a capture that found nothing: kind, and names what
    /// the box is for.
    static let emptyCaptureReply =
        "I didn't find anything to add there. This box is for what you need to get done, so tell me what's on your plate and I'll put it on the list."

    /// TRUE when the model's response carries no work at all: no new
    /// tasks, no updates, no study-plan question or answer, and nothing
    /// outstanding in the app that its message could be answering. Then
    /// the reply is the template, not the model's message.
    static func isEmptyCapture(_ response: ClaudeResponse, questionOutstanding: Bool) -> Bool {
        guard !questionOutstanding else { return false }
        return response.tasks.isEmpty
            && (response.taskUpdates ?? []).isEmpty
            && response.planQuestion == nil
            && (response.planConsent ?? []).isEmpty
    }
}
