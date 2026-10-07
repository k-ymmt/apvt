@testable import APVTCore
import Foundation
import Testing

@Suite("iOS Simulator platform pieces")
struct PlatformTests {
    /// `apvt teardown` / `setup` remove what earlier versions put into LLDB init files.
    @Test func oldLLDBHookIsRemovedCleanly() {
        let user = "settings set target.x 1\n"
        let old = "\(LegacyLLDBHook.begin)\ncommand script import \"/tmp/apvt_lldb.py\"\n\(LegacyLLDBHook.end)\n"
        #expect(LegacyLLDBHook.remove(from: user + old) == user)
        #expect(LegacyLLDBHook.remove(from: user) == user)
        #expect(LegacyLLDBHook.files.map(\.lastPathComponent) == [".lldbinit", ".lldbinit-Xcode"])
    }

    @Test func runtimeNamesReadLikeXcode() {
        #expect(Simctl.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-27-0") == "iOS 27.0")
        #expect(Simctl.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-26-5") == "watchOS 26.5")
    }

    @Test func errorsCarryWhyAndFix() {
        let error = APVTError(.environment, "no iOS simulator is booted", why: "because", fix: ["a", "b"])
        #expect(error.description == "error: no iOS simulator is booted\nwhy: because\nfix: a\n     b")
        #expect(error.exitCode == 3)
    }

    /// Builds the embedded agent sources for the simulator: they are not compiled by `swift build`.
    @Test(.enabled(if: (try? Shell.xcrun(["--sdk", "iphonesimulator", "--show-sdk-path"]).ok) == true))
    func agentAndLoaderBuildForTheSimulator() throws {
        let products = try AgentBuilder.ensure()
        #expect(FileManager.default.fileExists(atPath: products.agent.path))
        #expect(FileManager.default.fileExists(atPath: products.loader.path))
    }
}
