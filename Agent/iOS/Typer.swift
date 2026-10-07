import Foundation
import UIKit

/// Text entry for agents that drive the simulator with taps: synthesizing one tap per key is slow
/// and breaks on keyboard layouts, so the agent inserts the text into whatever has keyboard focus,
/// through the same `UIKeyInput` calls the keyboard makes. SwiftUI bindings, delegates and
/// `editingChanged` observers see it like typed text.
@MainActor
enum Typer {
    static func insert(_ request: AgentRequest) -> AgentTypeResponse {
        guard let responder = firstResponder() else {
            return AgentTypeResponse(ok: false, error: "nothing has keyboard focus: tap the text field first, then type")
        }
        guard let input = responder as? (UIResponder & UIKeyInput) else {
            return AgentTypeResponse(ok: false, error: "the focused \(type(of: responder)) does not accept text (not a UIKeyInput)",
                                     focused: describe(responder))
        }
        if request.replace == true {
            if let textInput = input as? UITextInput,
               let all = textInput.textRange(from: textInput.beginningOfDocument, to: textInput.endOfDocument) {
                textInput.selectedTextRange = all
                if !all.isEmpty { input.deleteBackward() }
            } else {
                var guardCount = 10_000
                while input.hasText && guardCount > 0 { input.deleteBackward(); guardCount -= 1 }
            }
        }
        let text = request.text ?? ""
        if !text.isEmpty { input.insertText(text) }
        if request.submit == true {
            // What the Return key does: the keyboard inserts "\n", and text fields turn it into
            // their return action (delegate textFieldShouldReturn, SwiftUI .onSubmit).
            input.insertText("\n")
        }
        // The focused view after the action (submit may move or drop focus).
        let after = firstResponder()
        return AgentTypeResponse(ok: true, focused: describe(responder), value: value(of: responder),
                                 focusedAfter: after.map(describe))
    }

    static func firstResponder() -> UIResponder? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        // The key window first: it is where typing goes.
        for window in windows.filter(\.isKeyWindow) + windows.filter({ !$0.isKeyWindow }) {
            if let found = find(in: window) { return found }
        }
        return nil
    }

    private static func find(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }

    private static func describe(_ responder: UIResponder) -> String {
        var parts = [String(describing: type(of: responder))]
        if let view = responder as? UIView, let id = view.accessibilityIdentifier, !id.isEmpty { parts.append("#\(id)") }
        if let field = responder as? UITextField, let placeholder = field.placeholder, !placeholder.isEmpty {
            parts.append("placeholder:\"\(placeholder)\"")
        }
        return parts.joined(separator: " ")
    }

    private static func value(of responder: UIResponder) -> String? {
        if let field = responder as? UITextField { return field.text }
        if let view = responder as? UITextView { return view.text }
        if let input = responder as? UITextInput,
           let all = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) {
            return input.text(in: all)
        }
        return nil
    }
}
