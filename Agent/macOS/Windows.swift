import AppKit
import Foundation

/// The app's windows as apvt counts them, and the one a request is about.
@MainActor
enum Windows {
    struct Selection {
        var window: NSWindow
        var info: WindowInfo
        var others: [WindowInfo]
    }

    /// Visible windows, frontmost first: `--window 1` is the front one.
    static func visible() throws -> [NSWindow] {
        guard let app = NSApp else {
            throw AgentFailure("the app has not created its NSApplication yet; retry in a moment (--wait 5)")
        }
        let candidates = app.windows.filter(isCandidate)
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
        func rank(_ window: NSWindow) -> Int { order.firstIndex(of: window.windowNumber) ?? Int.max }
        // Windows on another Space are not in the front-to-back list: they come last, as created.
        return candidates.enumerated().sorted { a, b in
            (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element)
    }

    /// The key window (a sheet, when one is up), the main window when the app is in the
    /// background, else the frontmost one — or the window `spec` names by number or title.
    static func select(_ spec: String?) throws -> Selection {
        let windows = try visible()
        guard !windows.isEmpty else {
            throw AgentFailure("the app has no visible window (it may be minimized, hidden, or still starting; --wait 5 after a launch)")
        }
        let infos = windows.enumerated().map { info($0.element, index: $0.offset + 1) }
        func listing() -> String { infos.map(describe).joined(separator: "; ") }
        var chosen: Int
        if let spec = spec?.trimmingCharacters(in: .whitespaces), !spec.isEmpty {
            if let number = Int(spec) {
                guard number >= 1, number <= windows.count else {
                    throw AgentFailure("there is no window \(number); the app's windows are: \(listing())")
                }
                chosen = number - 1
            } else {
                var matches = infos.indices.filter { infos[$0].title.caseInsensitiveCompare(spec) == .orderedSame }
                if matches.isEmpty { matches = infos.indices.filter { infos[$0].title.localizedCaseInsensitiveContains(spec) } }
                guard matches.count == 1 else {
                    throw AgentFailure("\(matches.isEmpty ? "no window is" : "\(matches.count) windows are") titled \"\(spec)\"; use a number: \(listing())")
                }
                chosen = matches[0]
            }
        } else {
            let app = NSApp!
            let preferred = app.keyWindow ?? app.mainWindow.map { $0.attachedSheet ?? $0 }
            chosen = preferred.flatMap { windows.firstIndex(of: $0) } ?? 0
        }
        var others = infos
        others.remove(at: chosen)
        return Selection(window: windows[chosen], info: infos[chosen], others: others)
    }

    static func describe(_ info: WindowInfo) -> String {
        var text = "\(info.index) \"\(info.title)\" \(Int(info.width.rounded()))x\(Int(info.height.rounded()))"
        if let kind = info.kind { text += " \(kind)" }
        if info.key { text += " (key)" }
        return text
    }

    private static func isCandidate(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.alphaValue > 0.01, window.frame.width >= 1, window.frame.height >= 1 else { return false }
        let name = NSStringFromClass(type(of: window))
        // Menu bar extras and full-screen scaffolding are the system's, not screens of the app.
        return !(name.contains("StatusBar") || name.contains("FullScreen") || name.contains("TouchBar"))
    }

    private static func info(_ window: NSWindow, index: Int) -> WindowInfo {
        let name = NSStringFromClass(type(of: window))
        var kind: String?
        if window.isSheet || window.sheetParent != nil { kind = "sheet" }
        else if name.contains("Popover") { kind = "popover" }
        else if name.contains("Menu") { kind = "menu" }
        else if window is NSPanel { kind = "panel" }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return WindowInfo(index: index, title: window.title, width: Double(window.frame.width), height: Double(window.frame.height),
                          key: window.isKeyWindow, kind: kind,
                          x: Double(window.frame.minX), y: Double(primaryHeight - window.frame.maxY))
    }
}

extension NSView {
    /// `rect` (in this view's coordinates, default its bounds) in window points from the
    /// window's top-left corner — the coordinates apvt reports on macOS.
    @MainActor
    func apvtFrame(_ rect: NSRect? = nil, flippedInput: Bool = false) -> Rect {
        var local = rect ?? bounds
        // SwiftUI records frames from the top-left; a view that is not flipped counts from the bottom.
        if flippedInput, !isFlipped { local.origin.y = bounds.height - local.maxY }
        let inWindow = convert(local, to: nil)
        let height = window?.frame.height ?? 0
        return Rect(x: Double(inWindow.minX), y: Double(height - inWindow.maxY), width: Double(inWindow.width), height: Double(inWindow.height))
    }
}
