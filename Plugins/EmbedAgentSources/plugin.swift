import Foundation
import PackagePlugin

/// Embeds the in-app agent's sources into APVTCore:
/// `Sources/APVTModel/*.swift` (group `model`), `Agent/iOS/*.swift` (`agent-ios`) and
/// `Agent/Loader/*.swift` (`loader`).
@main
struct EmbedAgentSources: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let root = context.package.directoryURL
        let groups: [(String, URL)] = [
            ("model", root.appending(path: "Sources/APVTModel")),
            ("agent-ios", root.appending(path: "Agent/iOS")),
            ("loader", root.appending(path: "Agent/Loader")),
        ]
        var inputs: [URL] = []
        var arguments: [String] = []
        let output = context.pluginWorkDirectoryURL.appending(path: "EmbeddedAgentSources.swift")
        arguments.append(output.path(percentEncoded: false))
        for (group, directory) in groups {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" {
                inputs.append(file)
                arguments.append("\(group)=\(file.path(percentEncoded: false))")
            }
        }
        return [
            .buildCommand(
                displayName: "Embedding apvt agent sources",
                executable: try context.tool(named: "apvt-embed").url,
                arguments: arguments,
                inputFiles: inputs,
                outputFiles: [output]
            ),
        ]
    }
}
