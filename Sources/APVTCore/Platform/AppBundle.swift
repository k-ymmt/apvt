import Foundation

/// A built `.app`, and which platform it was built for (read from its Info.plist).
struct AppBundle: Sendable {
    enum Kind: Sendable, Equatable {
        case macOS, iOSSimulator, iOSDevice, macCatalyst
        case other(String)
    }

    var url: URL
    var bundleId: String
    var name: String
    /// The main executable.
    var executable: URL
    var platform: Kind

    /// `MyApp.app`, `build/Debug/MyApp.app`, `./MyApp` — as opposed to a bundle id, which may
    /// end in ".app" too (`com.example.app`): that one is a path only if it is on disk.
    static func looksLikePath(_ text: String) -> Bool {
        if text.contains("/") || FileManager.default.fileExists(atPath: text) { return true }
        return text.hasSuffix(".app") && !text.dropLast(4).contains(".")
    }

    init(path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw APVTError(.usage, "there is no app at \(path)",
                            fix: ["build it first, then pass the .app in the build products (xcodebuild -showBuildSettings | grep -E 'BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME')"])
        }
        guard isDirectory.boolValue, url.pathExtension == "app" else {
            throw APVTError(.usage, "\(path) is not an .app bundle", why: "apvt launch takes the built .app (a folder ending in .app), not its executable or project.")
        }
        // macOS keeps Info.plist under Contents/, iOS at the bundle's top.
        let contents = url.appending(path: "Contents")
        let isMacLayout = FileManager.default.fileExists(atPath: contents.appending(path: "Info.plist").path)
        let plistURL = isMacLayout ? contents.appending(path: "Info.plist") : url.appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw APVTError(.usage, "\(url.lastPathComponent) has no readable Info.plist", why: "looked at \(plistURL.path).")
        }
        guard let bundleId = info["CFBundleIdentifier"] as? String, let executableName = info["CFBundleExecutable"] as? String else {
            throw APVTError(.usage, "\(url.lastPathComponent)'s Info.plist lacks CFBundleIdentifier or CFBundleExecutable")
        }
        self.url = url
        self.bundleId = bundleId
        name = info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        executable = (isMacLayout ? contents.appending(path: "MacOS") : url).appending(path: executableName)
        let platform = ((info["CFBundleSupportedPlatforms"] as? [String])?.first ?? info["DTPlatformName"] as? String ?? (isMacLayout ? "MacOSX" : "")).lowercased()
        switch platform {
        case "macosx": self.platform = info["UIDeviceFamily"] != nil ? .macCatalyst : .macOS
        case "iphonesimulator": self.platform = .iOSSimulator
        case "iphoneos": self.platform = .iOSDevice
        default: self.platform = .other(platform.isEmpty ? "unknown" : platform)
        }
    }

    var platformDescription: String {
        switch platform {
        case .macOS: "it was built for macOS."
        case .iOSSimulator: "it was built for the iOS Simulator."
        case .iOSDevice: "it was built for an iOS device (iphoneos), which apvt cannot look into."
        case .macCatalyst: "it is a Mac Catalyst app, which apvt does not support (AppKit and SwiftUI macOS apps only)."
        case .other(let name): "it was built for \(name), which apvt does not support."
        }
    }
}

/// Running processes by the executable they run (`NSWorkspace` needs a run loop to notice changes).
enum Processes {
    static func running(executable: URL) -> [Int32] {
        let wanted = executable.resolvingSymlinksInPath().path
        var pids = [Int32](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        var result: [Int32] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        // proc_listallpids returns a count of pids, not of bytes.
        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path == wanted || URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted { result.append(pid) }
        }
        return result
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
