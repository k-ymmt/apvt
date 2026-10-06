import Foundation

/// An error written for an agent that has to act on it: what happened, why, and what to run.
public struct APVTError: Error, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable, Codable {
        /// The command line was wrong.
        case usage
        /// The machine or simulator is not in a state apvt can work with.
        case environment
        /// The app or its agent did not answer as expected.
        case agent
        /// A file could not be read or written.
        case io
    }

    public var kind: Kind
    public var message: String
    public var why: String?
    /// Commands or steps that fix it, most likely first.
    public var fix: [String]

    public init(_ kind: Kind, _ message: String, why: String? = nil, fix: [String] = []) {
        self.kind = kind
        self.message = message
        self.why = why
        self.fix = fix
    }

    public var exitCode: Int32 {
        switch kind {
        case .usage: 2
        case .environment, .agent, .io: 3
        }
    }

    public var description: String {
        var lines = ["error: \(message)"]
        if let why { lines.append("why: \(why)") }
        for (i, step) in fix.enumerated() {
            lines.append(i == 0 ? "fix: \(step)" : "     \(step)")
        }
        return lines.joined(separator: "\n")
    }

    public var json: [String: Any] {
        var object: [String: Any] = ["error": message, "kind": kind.rawValue, "fix": fix]
        if let why { object["why"] = why }
        return object
    }
}
