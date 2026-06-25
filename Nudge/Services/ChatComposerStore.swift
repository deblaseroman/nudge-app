//
//  ChatComposerStore.swift
//  Nudge
//
//  Shared observable bridge between HomeTabView's composer and the floating
//  tab-bar button. When the user is on the chat tab and has typed something,
//  the floating button morphs from a chat bubble into a send arrow that
//  invokes `sendAction` here.
//
//  Battery / render-cost note: the tab bar only cares whether there IS
//  text, not what it is. So we expose `hasSendableText` as a stored Bool
//  and gate writes to "only update on transition." That way the tab bar
//  re-renders on the first keystroke and on the last, NOT on every key in
//  between. The full `text` is still available for the send action.
//

import Foundation
import Observation

@Observable
@MainActor
final class ChatComposerStore {
    static let shared = ChatComposerStore()

    /// Whether there is non-whitespace text in the composer right now.
    /// HomeTabView is responsible for keeping this in sync via
    /// `updateHasSendableText(from:)` which avoids re-firing observation
    /// on every keystroke.
    private(set) var hasSendableText: Bool = false

    /// Whether the AI request is in flight. Used to keep the button in a
    /// disabled/loading state.
    var isWaitingForAI: Bool = false

    /// The send closure registered by HomeTabView. The tab-bar button calls
    /// it directly when the user taps the morphed send icon.
    var sendAction: (() -> Void)?

    private init() {}

    /// Updates `hasSendableText` only if the boolean value actually changes
    /// — so the tab bar's observation tracker won't fire on every keystroke
    /// while text just gets longer. Call from HomeTabView's `onChange(of:
    /// composerText)`.
    func updateHasSendableText(from text: String) {
        let next = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if next != hasSendableText {
            hasSendableText = next
        }
    }

    /// Resets the store when the chat view goes away.
    func reset() {
        if hasSendableText { hasSendableText = false }
        if isWaitingForAI  { isWaitingForAI = false }
        sendAction = nil
    }
}
