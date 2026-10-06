// apvt's in-app agent for the iOS Simulator.
//
// Built by the host on first use (`xcrun --sdk iphonesimulator swiftc -emit-library`) together
// with `Sources/APVTModel`, and loaded into the app under test with no code of apvt's in the app:
//
// - `apvt setup` puts `Agent/Loader` into the simulator's launchd environment
//   (`DYLD_INSERT_LIBRARIES`); the loader dlopens this agent in user apps only.
// - `apvt setup --xcode` adds an auto-continuing breakpoint on `UIApplicationMain` to
//   `~/.lldbinit-Xcode` that dlopens this agent, for apps Xcode runs under its debugger (Xcode
//   passes its own DYLD_INSERT_LIBRARIES for the Main Thread Checker, which replaces launchd's).
//
// The agent serves a unix socket (`AgentWire`); it collects, the host judges.

import Foundation
import UIKit

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
        // SwiftUI reads this once, when it builds its first view graph. Loaded before
        // UIApplicationMain (launchd or the Xcode breakpoint), that is still ahead of us.
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
