import AppKit
import Foundation

/// What the agent's requests mean in a macOS app: every request is about one window.
enum AgentBackend {
    static let platform = Snapshot.macOS

    @MainActor static func snapshot(_ request: AgentRequest) throws -> Snapshot {
        let selection = try Windows.select(request.window)
        var collector = Collector(selection)
        return collector.snapshot()
    }

    @MainActor static func rawSwiftUIData(_ request: AgentRequest) throws -> Data {
        Collector(try Windows.select(request.window)).rawSwiftUIData()
    }

    @MainActor static func type(_ request: AgentRequest) -> AgentTypeResponse {
        Typer.insert(request)
    }

    @MainActor static func screenshot(_ request: AgentRequest) throws -> AgentScreenshotResponse {
        let selection = try Windows.select(request.window)
        let png = try WindowCapture.png(of: selection.window)
        return AgentScreenshotResponse(pngBase64: png.base64EncodedString(), window: selection.info)
    }
}
