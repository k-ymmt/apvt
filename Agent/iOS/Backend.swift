import Foundation
import UIKit

/// What the agent's requests mean in an iOS Simulator app.
enum AgentBackend {
    static let platform = Snapshot.iOSSimulator

    @MainActor static func snapshot(_ request: AgentRequest) throws -> Snapshot {
        var collector = Collector()
        return collector.snapshot()
    }

    @MainActor static func rawSwiftUIData(_ request: AgentRequest) throws -> Data {
        Collector().rawSwiftUIData()
    }

    @MainActor static func type(_ request: AgentRequest) -> AgentTypeResponse {
        Typer.insert(request)
    }

    /// The host photographs the simulator's screen itself (`simctl io screenshot`).
    @MainActor static func screenshot(_ request: AgentRequest) throws -> AgentScreenshotResponse {
        throw AgentFailure("screenshot is taken by the host on the iOS Simulator (simctl io screenshot)")
    }
}
