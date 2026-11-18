import AppKit
import Foundation

/// Text entry for agents: the text goes into whatever has keyboard focus in the window, through
/// `NSTextInputClient` as the input system does, so SwiftUI bindings, delegates and
/// `controlTextDidChange` observers see it like typed text.
@MainActor
enum Typer {
    static func insert(_ request: AgentRequest) -> AgentTypeResponse {
        let window: NSWindow
        do { window = try Windows.select(request.window).window } catch {
            return AgentTypeResponse(ok: false, error: (error as? AgentFailure)?.message ?? "\(error)")
        }
        guard let responder = focused(in: window) else {
            return AgentTypeResponse(ok: false, error: "nothing has keyboard focus in the window \"\(window.title)\": click the text field first, then type")
        }
        guard let input = responder as? NSTextInputClient else {
            return AgentTypeResponse(ok: false, error: "the focused \(Swift.type(of: responder)) does not accept text (not an NSTextInputClient)",
                                     focused: describe(responder))
        }
        let described = describe(responder)
        let text = request.text ?? ""
        if request.replace == true {
            if let textView = responder as? NSText {
                textView.selectAll(nil)
            }
            // Inserting over the selection replaces it; an empty string deletes it.
            input.insertText(text, replacementRange: input.selectedRange())
        } else if !text.isEmpty {
            input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // Read before Return: a text field's field editor lets go of the field when editing ends.
        var value = self.value(of: responder)
        if request.submit == true {
            // What the Return key does: a text field ends editing and sends its action
            // (SwiftUI .onSubmit); a text view inserts a line break.
            let owner = owningField(of: responder)
            responder.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            value = owner?.stringValue ?? self.value(of: responder) ?? value
        }
        let after = focused(in: window)
        return AgentTypeResponse(ok: true, focused: described, value: value, focusedAfter: after.map(describe))
    }

    /// The window's first responder when it is something that takes keys (the window itself
    /// is first responder when nothing is focused).
    private static func focused(in window: NSWindow) -> NSResponder? {
        guard let responder = window.firstResponder, !(responder is NSWindow) else { return nil }
        return responder
    }

    /// A text field is edited through the window's shared field editor: the field is its delegate.
    private static func owningField(of responder: NSResponder) -> NSTextField? {
        if let field = responder as? NSTextField { return field }
        if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSTextField }
        return nil
    }

    private static func describe(_ responder: NSResponder) -> String {
        if let field = owningField(of: responder) {
            var parts = [String(describing: Swift.type(of: field))]
            var id = field.accessibilityIdentifier()
            if id.isEmpty, let cell = field.cell { id = cell.accessibilityIdentifier() }
            if !id.isEmpty, !id.hasPrefix("_NS:") { parts.append("#\(id)") }
            if let placeholder = field.placeholderString, !placeholder.isEmpty { parts.append("placeholder:\"\(placeholder)\"") }
            return parts.joined(separator: " ")
        }
        var parts = [String(describing: Swift.type(of: responder))]
        if let view = responder as? NSView {
            let id = view.accessibilityIdentifier()
            if !id.isEmpty, !id.hasPrefix("_NS:") { parts.append("#\(id)") }
        }
        return parts.joined(separator: " ")
    }

    private static func value(of responder: NSResponder) -> String? {
        if let field = owningField(of: responder) { return field.stringValue }
        if let text = responder as? NSText { return text.string }
        return nil
    }
}
