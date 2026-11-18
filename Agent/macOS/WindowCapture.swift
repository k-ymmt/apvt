import AppKit
import Foundation

/// The window as a PNG at its backing scale, title bar included and without its shadow, so
/// pixels = points × scale from the window's top-left corner.
///
/// Taken inside the app: a process may capture its own windows without the Screen Recording
/// permission the host would need (measured on macOS 27: `CGPreflightScreenCaptureAccess` false,
/// image returned; also in a sandboxed app).
@MainActor
enum WindowCapture {
    static func png(of window: NSWindow) throws -> Data {
        if let image = windowServerImage(of: window) {
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) { return data }
        }
        // The window server's copy was not available: have the views draw themselves.
        guard let root = window.contentView?.superview ?? window.contentView,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw AgentFailure("could not capture the window \"\(window.title)\"")
        }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw AgentFailure("could not encode the capture of the window \"\(window.title)\" as PNG")
        }
        return data
    }

    /// `CGWindowListCreateImage` is unavailable to Swift in current SDKs (ScreenCaptureKit
    /// replaces it for other apps' windows) but still exported; for the app's own window it is
    /// the exact picture, materials and all.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        guard window.windowNumber > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        let image = unsafeBitCast(symbol, to: Create.self)(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
        guard let image, image.width > 1, image.height > 1 else { return nil }
        return image
    }
}
