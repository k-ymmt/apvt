@testable import APVTCore
import Foundation
import Testing

@Suite("iOS Simulator platform pieces")
struct PlatformTests {
    @Test func lldbHookBlockIsReplacedAndRemovedCleanly() {
        let user = "settings set target.x 1\n"
        let block = XcodeLLDBHook.block(agentPath: "/tmp/agent.dylib")
        #expect(block.contains("breakpoint set --name UIApplicationMain --auto-continue true"))
        #expect(block.contains("dlopen(\\\"/tmp/agent.dylib\\\", 2)"))
        let installed = user + block + "\n"
        #expect(XcodeLLDBHook.remove(from: installed) == user)
        #expect(XcodeLLDBHook.remove(from: user) == user)
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
