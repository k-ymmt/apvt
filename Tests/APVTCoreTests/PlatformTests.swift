@testable import APVTCore
import Foundation
import Testing

@Suite("iOS Simulator platform pieces")
struct PlatformTests {
    @Test func lldbHookBlockIsReplacedAndRemovedCleanly() {
        let user = "settings set target.x 1\n"
        let block = XcodeLLDBHook.block(scriptPath: "/tmp/apvt_lldb.py")
        #expect(block.contains("command script import \"/tmp/apvt_lldb.py\""))
        let installed = user + block + "\n"
        #expect(XcodeLLDBHook.remove(from: installed) == user)
        #expect(XcodeLLDBHook.remove(from: user) == user)
    }

    @Test func lldbScriptNeverStopsTheAppAndSetsOneBreakpoint() {
        let script = XcodeLLDBHook.script(agentPath: "/tmp/a \"b\"/libapvt-agent.dylib")
        #expect(script.contains("AGENT = \"/tmp/a \\\"b\\\"/libapvt-agent.dylib\""))
        #expect(script.contains("FindBreakpointsByName(NAME, existing)"))
        #expect(script.contains("bp.SetAutoContinue(True)"))
        #expect(script.components(separatedBy: "return False").count >= 4)
    }

    /// Xcode 27 debugs from `lldb-rpc-server`, which reads `~/.lldbinit`, not `~/.lldbinit-Xcode`.
    @Test func theHookGoesWhereXcodesDebuggerLooks() {
        #expect(XcodeLLDBHook.file.lastPathComponent == ".lldbinit")
        #expect(XcodeLLDBHook.legacyFile.lastPathComponent == ".lldbinit-Xcode")
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
