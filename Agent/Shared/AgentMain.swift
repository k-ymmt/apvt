// apvt's in-app agent: one dylib per platform, loaded into the app under test with no code of
// apvt's in the app.
//
// Built by the host on first use together with `Sources/APVTModel`: this folder plus `Agent/iOS`
// for the iOS Simulator (`xcrun --sdk iphonesimulator swiftc -emit-library`), or plus
// `Agent/macOS` for macOS apps.
//
// - iOS Simulator: `apvt setup` puts `Agent/Loader` into the simulator's launchd environment
//   (`DYLD_INSERT_LIBRARIES`); the loader dlopens this agent in user apps only.
// - macOS: `apvt launch` (or the variables of `apvt launch-env`) puts the agent itself into the
//   app's `DYLD_INSERT_LIBRARIES`.
//
// The agent serves `AgentWire`; it collects, the host judges. Each platform folder supplies
// `AgentBackend` (what a request means there) and `ConstraintMonitor`.

import Foundation

@used
@section("__DATA,__mod_init_func")
let apvtAgentInitializer: @convention(c) () -> Void = {
    APVTAgent.start()
}

enum APVTAgent {
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) static var swiftUIDebug = false

    static func start() {
        guard !started, getenv("APVT_AGENT_STARTED") == nil else { return }
        started = true
        setenv("APVT_AGENT_STARTED", "1", 1)
        // (The variable is inherited: a child process that also loads the dylib does nothing.)
        // SwiftUI reads this once, when it builds its first view graph. Loaded before the app's
        // main(), that is still ahead of us.
        if getenv(AgentWire.swiftUIDebugVariable) == nil {
            setenv(AgentWire.swiftUIDebugVariable, "31", 1)
        }
        swiftUIDebug = true
        ConstraintMonitor.install()
        AgentServer.start()
    }

    static func log(_ message: String) {
        NSLog("[apvt-agent] %@", message)
    }
}

/// Why a request could not be answered, in words the host passes on.
struct AgentFailure: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
