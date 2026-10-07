@testable import APVTCore
import APVTModel
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

    /// `apvt type` travels as optional fields, so an agent from before it still decodes requests.
    @Test func typeRequestRoundTripsAndOldRequestsStillDecode() throws {
        let request = AgentRequest(cmd: "type", text: "Buy eggs", replace: true, submit: false)
        let decoded = try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.cmd == "type" && decoded.text == "Buy eggs" && decoded.replace == true && decoded.submit == false)
        let old = try JSONDecoder().decode(AgentRequest.self, from: Data(#"{"cmd":"snapshot"}"#.utf8))
        #expect(old.text == nil && old.replace == nil && old.submit == nil)
        let response = try JSONDecoder().decode(AgentTypeResponse.self, from: Data(#"{"ok":true,"focused":"UITextField #name","value":"Ann"}"#.utf8))
        #expect(response.ok && response.value == "Ann" && response.focusedAfter == nil)
    }

    /// `apvt launch-env` hands Xcode the agent itself (no loader needed: the launch is the app's).
    @Test(.enabled(if: (try? Shell.xcrun(["--sdk", "iphonesimulator", "--show-sdk-path"]).ok) == true))
    func launchEnvironmentPointsAtTheAgent() throws {
        let env = try Session.launchEnvironment(device: "no-such-simulator")
        #expect(env["DYLD_INSERT_LIBRARIES"] == AgentBuilder.currentAgent.path)
        #expect(env["APVT_LOADED_BY"] == "env")
        #expect(FileManager.default.fileExists(atPath: env["DYLD_INSERT_LIBRARIES"]!))
    }
}
